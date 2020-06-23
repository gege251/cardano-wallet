{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Copyright: © 2020 IOHK
-- License: Apache-2.0
--
-- Haskell-node "shelley" implementation of the @StakePoolLayer@ abstraction,
-- i.e. some boring glue.
module Cardano.Wallet.Shelley.Pools where

import Prelude

import Cardano.BM.Data.Severity
    ( Severity (..) )
import Cardano.BM.Data.Tracer
    ( HasPrivacyAnnotation (..), HasSeverityAnnotation (..) )
import Cardano.Pool.DB
    ( DBLayer (..), ErrPointAlreadyExists (..) )
import Cardano.Wallet.Api.Types
    ( ApiT (..) )
import Cardano.Wallet.Network
    ( ErrNetworkUnavailable
    , FollowAction (..)
    , FollowExit (..)
    , FollowLog
    , NetworkLayer (..)
    , follow
    )
import Cardano.Wallet.Primitive.Types
    ( ActiveSlotCoefficient (..)
    , BlockHeader
    , Coin (..)
    , GenesisParameters (..)
    , PoolId
    , PoolRegistrationCertificate (..)
    , ProtocolParameters
    , SlotId
    , SlotLength (..)
    , StakePoolMetadata
    , StakePoolMetadataHash
    , StakePoolMetadataUrl
    )
import Cardano.Wallet.Shelley.Compatibility
    ( Shelley
    , ShelleyBlock
    , fromShelleyBlock'
    , getProducer
    , toBlockHeader
    , toPoint
    )
import Cardano.Wallet.Shelley.Network
    ( NodePoolLsqData (..) )
import Cardano.Wallet.Unsafe
    ( unsafeMkPercentage, unsafeRunExceptT )
import Control.Concurrent
    ( threadDelay )
import Control.Monad
    ( forM, forM_, forever, when )
import Control.Monad.IO.Class
    ( liftIO )
import Control.Monad.Trans.Except
    ( ExceptT (..), runExceptT )
import Control.Tracer
    ( Tracer, contramap, traceWith )
import Data.List.NonEmpty
    ( NonEmpty (..) )
import Data.Map
    ( Map )
import Data.Map.Merge.Strict
    ( dropMissing, traverseMissing, zipWithMatched )
import Data.Maybe
    ( catMaybes )
import Data.Ord
    ( Down (..) )
import Data.Quantity
    ( Percentage (..), Quantity (..) )
import Data.Sort
    ( sortOn )
import Data.Text.Class
    ( ToText (..) )
import Data.Word
    ( Word64 )
import Fmt
    ( fixedF, pretty )
import GHC.Generics
    ( Generic )

import qualified Cardano.Wallet.Api.Types as Api
import qualified Data.Map.Merge.Strict as Map
import qualified Data.Map.Strict as Map
import qualified Data.Text as T

-- | Stake Pool Data fields fetched from the node via LSQ
data PoolLsqMetrics = PoolLsqMetrics
    { nonMyopicMemberRewards :: Quantity "lovelace" Word64
    , relativeStake :: Percentage
    , saturation :: Double
    } deriving (Eq, Show, Generic)

combineLsqData
    :: NodePoolLsqData
    -> Map PoolId PoolLsqMetrics
combineLsqData NodePoolLsqData{nOpt, rewards, stake} =
    Map.merge stakeButNoRewards rewardsButNoStake bothPresent stake rewards
  where
    -- calculate the saturation from the relative stake
    sat s = fromRational $ (getPercentage s) / (1 / fromIntegral nOpt)

    -- If we fetch non-myopic member rewards of pools using the wallet
    -- balance of 0, the resulting map will be empty. So we set the rewards
    -- to 0 here:
    stakeButNoRewards = traverseMissing $ \_k s -> pure $ PoolLsqMetrics
        { nonMyopicMemberRewards = Quantity 0
        , relativeStake = s
        , saturation = (sat s)
        }

    rewardsButNoStake = dropMissing

    bothPresent       = zipWithMatched  $ \_k s r -> PoolLsqMetrics r s (sat s)

readBlockProductions :: IO (Map PoolId Int)
readBlockProductions = return Map.empty

--
-- Api Server Handler
--

data StakePoolLayer = StakePoolLayer
    { knownPools :: IO [PoolId]
    , listStakePools :: Coin -> ExceptT ErrNetworkUnavailable IO [Api.ApiStakePool]
    }

newStakePoolLayer
    :: GenesisParameters
    -> NetworkLayer IO (IO Shelley) b
    -> StakePoolLayer
newStakePoolLayer gp nl = StakePoolLayer
    { knownPools = _knownPools
    , listStakePools = _listPools
    }
  where
    dummyCoin = Coin 0

    -- Note: We shouldn't have to do this conversion.
    el = getEpochLength gp
    gh = getGenesisBlockHash gp
    getTip = fmap (toPoint gh el) . liftIO $ unsafeRunExceptT $ currentNodeTip nl

    _knownPools
        :: IO [PoolId]
    _knownPools = do
        pt <- getTip
        res <- runExceptT $ map fst . Map.toList
            . combineLsqData <$> stakeDistribution nl pt dummyCoin
        case res of
            Right x -> return x
            Left _e -> return []


    _listPools
        :: Coin
        -- ^ The amount of stake the user intends to delegate, which may affect the
        -- ranking of the pools.
        -> ExceptT ErrNetworkUnavailable IO [Api.ApiStakePool]
    _listPools s = do
            pt <- liftIO getTip
            map mkApiPool
                . sortOn (Down . nonMyopicMemberRewards . snd)
                . Map.toList
                . combineLsqData
                <$> stakeDistribution nl pt s
      where
        mkApiPool (pid, PoolLsqMetrics prew pstk psat) = Api.ApiStakePool
            { Api.id = (ApiT pid)
            , Api.metrics = Api.ApiStakePoolMetrics
                { Api.nonMyopicMemberRewards = (mapQ fromIntegral prew)
                , Api.relativeStake = Quantity pstk
                , Api.saturation = psat
                , Api.producedBlocks = Quantity 0 -- TODO: Implement
                }
            , Api.metadata = Nothing -- TODO: Implement
            , Api.cost = Quantity 0 -- TODO: Implement
            , Api.margin = Quantity $ unsafeMkPercentage 0 -- TODO: Implement
            }

        mapQ f (Quantity x) = Quantity $ f x


--
-- Monitoring stake pool
--

monitorStakePools
    :: Tracer IO StakePoolLog
    -> GenesisParameters
    -> NetworkLayer IO t ShelleyBlock
    -> DBLayer IO
    -> IO ()
monitorStakePools tr gp nl db@DBLayer{..} = do
    cursor <- initCursor
    traceWith tr $ MsgStartMonitoring cursor
    follow nl (contramap MsgFollow tr) cursor forward getHeader >>= \case
        FollowInterrupted -> traceWith tr MsgHaltMonitoring
        FollowFailure -> traceWith tr MsgCrashMonitoring
        FollowRollback point -> do
            traceWith tr $ MsgRollingBackTo point
            liftIO . atomically $ rollbackTo point
            monitorStakePools tr gp nl db
  where
    GenesisParameters
        { getGenesisBlockHash
        , getEpochLength
        , getEpochStability
        } = gp

    initCursor :: IO [BlockHeader]
    initCursor = atomically $ readPoolProductionCursor (max 100 k)
      where k = fromIntegral $ getQuantity getEpochStability

    getHeader :: ShelleyBlock -> BlockHeader
    getHeader = toBlockHeader getGenesisBlockHash getEpochLength

    forward
        :: NonEmpty ShelleyBlock
        -> (BlockHeader, ProtocolParameters)
        -> IO (FollowAction ())
    forward blocks (_nodeTip, _pparams) = do
        atomically $ forM_ blocks $ \blk -> do
            let (slot, registrations) = fromShelleyBlock' getEpochLength blk
            runExceptT (putPoolProduction (getHeader blk) (getProducer blk)) >>= \case
                Left e   -> liftIO $ traceWith tr $ MsgErrProduction e
                Right () -> pure ()
            forM_ registrations $ \pool -> do
                liftIO $ traceWith tr $ MsgStakePoolRegistration pool
                putPoolRegistration slot pool
        pure Continue

monitorMetadata
    :: Tracer IO StakePoolLog
    -> GenesisParameters
    -> (StakePoolMetadataUrl -> StakePoolMetadataHash -> IO (Either String StakePoolMetadata))
    -> DBLayer IO
    -> IO ()
monitorMetadata tr gp fetchMetadata DBLayer{..} = forever $ do
    refs <- atomically (unfetchedPoolMetadataRefs 100)

    successes <- fmap catMaybes $ forM refs $ \(pid, url, hash) -> do
        traceWith tr $ MsgFetchPoolMetadata pid url
        fetchMetadata url hash >>= \case
            Left msg -> Nothing <$ do
                traceWith tr $ MsgFetchPoolMetadataFailure pid msg

            Right meta -> Just pid <$ do
                traceWith tr $ MsgFetchPoolMetadataSuccess pid meta
                atomically $ putPoolMetadata pid hash meta

    when (null refs || null successes) $ do
        traceWith tr $ MsgFetchTakeBreak blockFrequency
        threadDelay blockFrequency
  where
    -- NOTE
    -- If there's no metadata, we typically need not to retry sooner than the
    -- next block. So waiting for a delay that is roughly the same order of
    -- magnitude as the (slot length / active slot coeff) sounds sound.
    blockFrequency = ceiling (1/f) * toMicroSecond slotLength
      where
        toMicroSecond = (`div` 1000000) . fromEnum
        slotLength = unSlotLength $ getSlotLength gp
        f = unActiveSlotCoefficient (getActiveSlotCoefficient gp)

data StakePoolLog
    = MsgFollow FollowLog
    | MsgStartMonitoring [BlockHeader]
    | MsgHaltMonitoring
    | MsgCrashMonitoring
    | MsgRollingBackTo SlotId
    | MsgStakePoolRegistration PoolRegistrationCertificate
    | MsgErrProduction ErrPointAlreadyExists
    | MsgFetchPoolMetadata PoolId StakePoolMetadataUrl
    | MsgFetchPoolMetadataSuccess PoolId StakePoolMetadata
    | MsgFetchPoolMetadataFailure PoolId String
    | MsgFetchTakeBreak Int
    deriving (Show, Eq)

instance HasPrivacyAnnotation StakePoolLog
instance HasSeverityAnnotation StakePoolLog where
    getSeverityAnnotation = \case
        MsgFollow e -> getSeverityAnnotation e
        MsgStartMonitoring{} -> Info
        MsgHaltMonitoring{} -> Info
        MsgCrashMonitoring{} -> Error
        MsgRollingBackTo{} -> Info
        MsgStakePoolRegistration{} -> Info
        MsgErrProduction{} -> Error
        MsgFetchPoolMetadata{} -> Info
        MsgFetchPoolMetadataSuccess{} -> Info
        MsgFetchPoolMetadataFailure{} -> Warning
        MsgFetchTakeBreak{} -> Info -- TODO Lower to "Debug"

instance ToText StakePoolLog where
    toText = \case
        MsgFollow e ->
            toText e
        MsgStartMonitoring cursor -> mconcat
            [ "Monitoring stake pools. Currently at "
            , case cursor of
                [] -> "genesis"
                _  -> pretty (last cursor)
            ]
        MsgHaltMonitoring ->
            "Stopping stake pool monitoring as requested."
        MsgCrashMonitoring ->
            "Chain follower exited with error. Worker will no longer monitor stake pools."
        MsgRollingBackTo point ->
            "Rolling back to " <> pretty point
        MsgStakePoolRegistration pool ->
            "Discovered stake pool registration: " <> pretty pool
        MsgErrProduction (ErrPointAlreadyExists blk) -> mconcat
            [ "Couldn't store production for given block before it conflicts "
            , "with another block. Conflicting block header is: ", pretty blk
            ]
        MsgFetchPoolMetadata pid url -> mconcat
            [ "Fetching metadata for pool ", pretty pid, " from ", toText url
            ]
        MsgFetchPoolMetadataSuccess pid meta -> mconcat
            [ "Successfully fetched metadata for pool ", pretty pid
            , ": ", T.pack (show meta)
            ]
        MsgFetchPoolMetadataFailure pid msg -> mconcat
            [ "Failed to fetch metadata for pool ", pretty pid, ": ", T.pack msg
            ]
        MsgFetchTakeBreak delay -> mconcat
            [ "Taking a little break from fetching metadata, back to it in about "
            , pretty (fixedF 1 (toRational delay / 1000000)), "s"
            ]
