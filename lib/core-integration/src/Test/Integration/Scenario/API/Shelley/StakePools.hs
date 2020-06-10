{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Test.Integration.Scenario.API.Shelley.StakePools
    ( spec
    ) where

import Prelude

import Cardano.Wallet.Api.Types
    ( ApiT (..)
    , ApiTransaction
    , ApiWallet
    , DecodeAddress
    , EncodeAddress
    , WalletStyle (..)
    )
import Cardano.Wallet.Primitive.AddressDerivation
    ( PaymentAddress, fromHex )
import Cardano.Wallet.Primitive.AddressDerivation.Shelley
    ( ShelleyKey )
import Cardano.Wallet.Primitive.Types
    ( Direction (..), PoolId (..), TxStatus (..) )
import Data.ByteString
    ( ByteString )
import Data.Generics.Internal.VL.Lens
    ( (^.) )
import Data.Text.Class
    ( toText )
import Test.Hspec
    ( SpecWith, it, shouldBe )
import Test.Integration.Framework.DSL
    ( Context (..)
    , Headers (..)
    , Payload (..)
    , emptyWallet
    , eventually
    , expectErrorMessage
    , expectField
    , expectListField
    , expectResponseCode
    , fixturePassphrase
    , fixtureWallet
    , joinStakePool
    , request
    , verify
    , walletId
    )
import Test.Integration.Framework.TestData
    ( errMsg403WrongPass, errMsg404NoSuchPool, errMsg404NoWallet )

import qualified Cardano.Wallet.Api.Link as Link
import qualified Data.ByteString as BS
import qualified Network.HTTP.Types.Status as HTTP


spec :: forall n t.
    ( DecodeAddress n
    , EncodeAddress n
    , PaymentAddress n ShelleyKey
    ) => SpecWith (Context t)
spec = do
    it "STAKE_POOLS_JOIN_01 - Cannot join with empty wallet" $ \ctx -> do
        w <- emptyWallet ctx
        let wid = w ^. walletId
        _ <- request @ApiWallet ctx
            (Link.deleteWallet @'Shelley w) Default Empty
        let poolIdAbsent = PoolId $ BS.pack $ replicate 32 1
        r <- joinStakePool @n ctx (ApiT poolIdAbsent) (w, fixturePassphrase)
        expectResponseCode HTTP.status404 r
        expectErrorMessage (errMsg404NoWallet wid) r

    it "STAKE_POOLS_JOIN_01 - Cannot join non-existant stakepool" $ \ctx -> do
        w <- fixtureWallet ctx
        let poolIdAbsent = PoolId $ BS.pack $ replicate 32 1
        r <- joinStakePool @n ctx (ApiT poolIdAbsent) (w, fixturePassphrase)
        expectResponseCode HTTP.status404 r
        expectErrorMessage (errMsg404NoSuchPool (toText poolIdAbsent)) r

    it "STAKE_POOLS_JOIN_01 - Cannot join existant stakepool when wrong password" $ \ctx -> do
        w <- fixtureWallet ctx
        r <- joinStakePool @n ctx (ApiT poolIdMock) (w, "Wrong Passphrase")
        expectResponseCode HTTP.status403 r
        expectErrorMessage errMsg403WrongPass r

    it "STAKE_POOLS_JOIN_01 - Can join existant stakepool" $ \ctx -> do
        w <- fixtureWallet ctx
        joinStakePool @n ctx (ApiT poolIdMock) (w, fixturePassphrase) >>= flip verify
            [ expectResponseCode HTTP.status202
            , expectField (#status . #getApiT) (`shouldBe` Pending)
            , expectField (#direction . #getApiT) (`shouldBe` Outgoing)
            ]

        -- Wait for the certificate to be inserted
        eventually "Certificates are inserted" $ do
            let ep = Link.listTransactions @'Shelley w
            request @[ApiTransaction n] ctx ep Default Empty >>= flip verify
                [ expectListField 0
                    (#direction . #getApiT) (`shouldBe` Outgoing)
                , expectListField 0
                    (#status . #getApiT) (`shouldBe` InLedger)
                ]
    it "STAKE_POOLS_JOIN_01 - Can rejoin another stakepool" $ \ctx -> do
        w <- fixtureWallet ctx
        joinStakePool @n ctx (ApiT poolIdMock) (w, fixturePassphrase) >>= flip verify
            [ expectResponseCode HTTP.status202
            , expectField (#status . #getApiT) (`shouldBe` Pending)
            , expectField (#direction . #getApiT) (`shouldBe` Outgoing)
            ]

        -- Wait for the certificate to be inserted
        eventually "Certificates are inserted" $ do
            let ep = Link.listTransactions @'Shelley w
            request @[ApiTransaction n] ctx ep Default Empty >>= flip verify
                [ expectListField 0
                    (#direction . #getApiT) (`shouldBe` Outgoing)
                , expectListField 0
                    (#status . #getApiT) (`shouldBe` InLedger)
                ]

        -- join another stake pool
        joinStakePool @n ctx (ApiT poolIdMock') (w, fixturePassphrase) >>= flip verify
            [ expectResponseCode HTTP.status202
            , expectField (#status . #getApiT) (`shouldBe` Pending)
            , expectField (#direction . #getApiT) (`shouldBe` Outgoing)
            ]

        -- Wait for the certificate to be inserted
        eventually "Certificates are inserted" $ do
            let ep = Link.listTransactions @'Shelley w
            request @[ApiTransaction n] ctx ep Default Empty >>= flip verify
                [ expectListField 1
                    (#direction . #getApiT) (`shouldBe` Outgoing)
                , expectListField 1
                    (#status . #getApiT) (`shouldBe` InLedger)
                ]

  where
    (Right poolID) = fromHex @ByteString "5a7b67c7dcfa8c4c25796bea05bcdfca01590c8c7612cc537c97012bed0dec35"
    poolIdMock = PoolId poolID
    (Right poolID') = fromHex @ByteString "775af3b22eff9ff53a0bdd3ac6f8e1c5013ab68445768c476ccfc1e1c6b629b4"
    poolIdMock' = PoolId poolID'
