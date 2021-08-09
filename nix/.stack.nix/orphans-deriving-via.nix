{ system
  , compiler
  , flags
  , pkgs
  , hsPkgs
  , pkgconfPkgs
  , errorHandler
  , config
  , ... }:
  {
    flags = { development = false; };
    package = {
      specVersion = "1.10";
      identifier = { name = "orphans-deriving-via"; version = "0.1.0.0"; };
      license = "Apache-2.0";
      copyright = "IOHK";
      maintainer = "operations@iohk.io";
      author = "IOHK";
      homepage = "";
      url = "";
      synopsis = "Orphan instances for the base-deriving-via hooks";
      description = "";
      buildType = "Simple";
      isLocal = true;
      };
    components = {
      "library" = {
        depends = [
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."base-deriving-via" or (errorHandler.buildDepError "base-deriving-via"))
          (hsPkgs."deepseq" or (errorHandler.buildDepError "deepseq"))
          (hsPkgs."nothunks" or (errorHandler.buildDepError "nothunks"))
          ];
        buildable = true;
        };
      };
    } // {
    src = (pkgs.lib).mkDefault (pkgs.fetchgit {
      url = "https://github.com/input-output-hk/cardano-base";
      rev = "8c732560b201b5da8e3bdf175c6eda73a32d64bc";
      sha256 = "0nwy03wyd2ks4qxg47py7lm18karjz6vs7p8knmn3zy72i3n9rfi";
      }) // {
      url = "https://github.com/input-output-hk/cardano-base";
      rev = "8c732560b201b5da8e3bdf175c6eda73a32d64bc";
      sha256 = "0nwy03wyd2ks4qxg47py7lm18karjz6vs7p8knmn3zy72i3n9rfi";
      };
    postUnpack = "sourceRoot+=/orphans-deriving-via; echo source root reset to \$sourceRoot";
    }