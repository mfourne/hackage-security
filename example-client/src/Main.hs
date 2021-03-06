module Main where

-- stdlib
import Control.Exception
import Control.Monad
import Data.Time
import qualified Data.ByteString.Lazy as BS.L

-- Cabal
import Distribution.Package

-- hackage-security
import Hackage.Security.Client
import Hackage.Security.Util.Path
import Hackage.Security.Util.Pretty
import Hackage.Security.Util.Some
import Hackage.Security.Client.Repository.HttpLib
import qualified Hackage.Security.Client.Repository.Cache       as Cache
import qualified Hackage.Security.Client.Repository.Local       as Local
import qualified Hackage.Security.Client.Repository.Remote      as Remote
import qualified Hackage.Security.Client.Repository.HttpLib.HTTP as HttpLib.HTTP
import qualified Hackage.Security.Client.Repository.HttpLib.Curl as HttpLib.Curl
import qualified Hackage.Security.Client.Repository.HttpLib.HttpClient as HttpLib.HttpClient

-- example-client
import ExampleClient.Options

main :: IO ()
main = do
    opts@GlobalOpts{..} <- getOptions
    case globalCommand of
      Bootstrap threshold -> cmdBootstrap opts threshold
      Check               -> cmdCheck     opts
      Get       pkgId     -> cmdGet       opts pkgId
      EnumIndex newOnly   -> cmdEnumIndex opts newOnly
      GetCabal  pkgId     -> cmdGetCabal  opts pkgId
      GetHash   pkgId     -> cmdGetHash   opts pkgId

{-------------------------------------------------------------------------------
  The commands are just thin wrappers around the hackage-security Client API
-------------------------------------------------------------------------------}

cmdBootstrap :: GlobalOpts -> KeyThreshold -> IO ()
cmdBootstrap opts threshold =
    withRepo opts $ \rep -> uncheckClientErrors $ do
      bootstrap rep (globalRootKeys opts) threshold
      putStrLn "OK"

cmdCheck :: GlobalOpts -> IO ()
cmdCheck opts =
    withRepo opts $ \rep -> uncheckClientErrors $ do
      mNow <- if globalCheckExpiry opts
                then Just `fmap` getCurrentTime
                else return Nothing
      print =<< checkForUpdates rep mNow

cmdGet :: GlobalOpts -> PackageIdentifier -> IO ()
cmdGet opts pkgId = do
    cwd <- getCurrentDirectory
    let localFile = cwd </> fragment tarGzName
    withRepo opts $ \rep -> uncheckClientErrors $
      downloadPackage rep pkgId localFile
  where
    tarGzName :: String
    tarGzName = takeFileName $ repoLayoutPkgTarGz hackageRepoLayout pkgId

cmdEnumIndex :: GlobalOpts -> NewOnly -> IO ()
cmdEnumIndex opts False =
    withRepo opts $ \rep -> uncheckClientErrors $ do
      dir <- getDirectory rep
      forM_ (directoryEntries dir) $ putStrLn . aux
  where
    aux :: (Pretty fp, Pretty file) => (DirectoryEntry, fp, Maybe file) -> String
    aux (_, _,  Just file) = pretty file
    aux (_, fp, Nothing  ) = "unrecognized: " ++ pretty fp
cmdEnumIndex opts True = do
    withRepo opts $ \rep -> uncheckClientErrors $ do
      withIndex rep $ \IndexCallbacks{..} -> do
        let go n = do (Some IndexEntry{..}, mNext) <- indexLookupEntry n
                      putStrLn $ pretty indexEntryPath
                      case mNext of
                        Nothing   -> return ()
                        Just next -> go next
        startingPoint <- getStartingPoint (directoryFirst indexDirectory)
        if (startingPoint == directoryNext indexDirectory)
          then putStrLn "No new entries"
          else do
            go startingPoint
            saveStartingPoint $ directoryNext indexDirectory
  where
    getStartingPoint :: DirectoryEntry -> IO DirectoryEntry
    getStartingPoint def =
      catch (read <$> readFile marker)
            (\(SomeException _) -> return def)

    saveStartingPoint :: DirectoryEntry -> IO ()
    saveStartingPoint = writeFile marker . show

    marker :: FilePath
    marker = toFilePath (globalCache opts </> fragment "enum.marker")

cmdGetCabal :: GlobalOpts -> PackageIdentifier -> IO ()
cmdGetCabal opts pkgId =
    withRepo opts $ \rep -> uncheckClientErrors $
      withIndex rep $ \IndexCallbacks{..} ->
        BS.L.putStr . trusted =<< indexLookupCabal pkgId

cmdGetHash :: GlobalOpts -> PackageIdentifier -> IO ()
cmdGetHash opts pkgId =
    withRepo opts $ \rep -> uncheckClientErrors $
      withIndex rep $ \IndexCallbacks{..} ->
        print =<< indexLookupHash pkgId

{-------------------------------------------------------------------------------
  Common functionality
-------------------------------------------------------------------------------}

withRepo :: GlobalOpts
         -> (forall down. DownloadedFile down => Repository down -> IO a)
         -> IO a
withRepo GlobalOpts{..} = \callback ->
    case globalRepo of
      Left  local  -> withLocalRepo  local  callback
      Right remote -> withRemoteRepo remote callback
  where
    withLocalRepo :: Path Absolute -> (Repository Local.LocalFile -> IO a) -> IO a
    withLocalRepo repo =
        Local.withRepository repo
                             cache
                             hackageRepoLayout
                             hackageIndexLayout
                             logTUF

    withRemoteRepo :: URI -> (Repository Remote.RemoteTemp -> IO a) -> IO a
    withRemoteRepo baseURI callback = withClient $ \httpClient ->
        Remote.withRepository httpClient
                              [baseURI]
                              repoOpts
                              cache
                              hackageRepoLayout
                              hackageIndexLayout
                              logTUF
                              callback

    repoOpts :: Remote.RepoOpts
    repoOpts = Remote.defaultRepoOpts

    withClient :: (HttpLib -> IO a) -> IO a
    withClient act =
        case globalHttpClient of
          "HTTP" ->
            HttpLib.HTTP.withClient $ \browser httpLib -> do
              HttpLib.HTTP.setProxy      browser proxyConfig
              HttpLib.HTTP.setOutHandler browser logHTTP
              HttpLib.HTTP.setErrHandler browser logHTTP
              act httpLib
          "curl" ->
            HttpLib.Curl.withClient $ \httpLib ->
              act httpLib
          "http-client" ->
            HttpLib.HttpClient.withClient proxyConfig $ \_manager httpLib ->
              act httpLib
          otherClient ->
            error $ "unsupported HTTP client " ++ show otherClient

    -- use automatic proxy configuration
    proxyConfig :: forall a. ProxyConfig a
    proxyConfig = ProxyConfigAuto

    -- used for log messages from the Hackage.Security code
    logTUF :: LogMessage -> IO ()
    logTUF msg = putStrLn $ "# " ++ pretty msg

    -- used for log messages from the HTTP clients
    logHTTP :: String -> IO ()
    logHTTP = putStrLn

    cache :: Cache.Cache
    cache = Cache.Cache {
        cacheRoot   = globalCache
      , cacheLayout = cabalCacheLayout
      }
