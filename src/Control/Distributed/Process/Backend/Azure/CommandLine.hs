{-# LANGUAGE TemplateHaskell #-}
import Prelude hiding (catch)
import System.Environment (getArgs)
import System.Exit (exitSuccess, exitFailure)
import System.IO 
  ( hFlush
  , stdout
  , stdin
  , hSetBinaryMode
  )
import Data.Binary (decode)  
import qualified Data.ByteString.Lazy as BSL (ByteString, length, getContents)
import Control.Monad (unless, forM, forM_, join)
import Control.Monad.IO.Class (liftIO)
import Control.Arrow (returnA)
import Control.Exception (throwIO, SomeException)
import Control.Distributed.Process.Backend.Azure 
  ( AzureParameters(azureSshUserName)
  , defaultAzureParameters
  , initializeBackend 
  , cloudServices 
  , CloudService(cloudServiceName, cloudServiceVMs)
  , VirtualMachine(vmName)
  , Backend(copyToVM, checkMD5, runOnVM)
  )
import qualified Network.SSH.Client.LibSSH2.Foreign as SSH
  ( initialize 
  , exit
  )
import Control.Applicative ((<$>), (<*>), (<|>), pure)
import Options.Applicative 
  ( Parser
  , strOption
  , long
  , (&)
  , metavar
  , help
  , subparser
  , command
  , info
  , progDesc 
  , execParser
  , helper
  , fullDesc
  , header
  , switch
  )
import Options.Applicative.Arrows (runA, asA)
import Control.Distributed.Process 
  ( getSelfPid
  , RemoteTable
  , Closure
  , Process
  , unClosure
  , catch
  )
import Control.Distributed.Process.Closure (remotable, mkClosure)
import Control.Distributed.Process.Node (newLocalNode, runProcess, initRemoteTable)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

cprint :: String -> Process ()
cprint = liftIO . putStrLn

remotable ['cprint]

--------------------------------------------------------------------------------
-- Main                                                                       -- 
--------------------------------------------------------------------------------

main :: IO ()
main = do 
    _ <- SSH.initialize True
    cmd <- execParser opts
    case cmd of
      List {} -> do
        params <- azureParameters (azureOptions cmd) Nothing
        backend <- initializeBackend params 
        css <- cloudServices backend
        mapM_ print css
      CopyTo {} -> do
        params <- azureParameters (azureOptions cmd) (Just (sshOptions cmd))
        backend <- initializeBackend params
        css <- cloudServices backend
        forM_ (findTarget (target cmd) css) $ \vm -> do
          putStr (vmName vm ++ ": ") >> hFlush stdout 
          copyToVM backend vm 
          putStrLn "Done"
      CheckMD5 {} -> do
        params <- azureParameters (azureOptions cmd) (Just (sshOptions cmd))
        backend <- initializeBackend params
        css <- cloudServices backend
        matches <- forM (findTarget (target cmd) css) $ \vm -> do
          unless (status cmd) $ putStr (vmName vm ++ ": ") >> hFlush stdout
          match <- checkMD5 backend vm 
          unless (status cmd) $ putStrLn $ if match then "OK" else "FAILED"
          return match
        if and matches
          then exitSuccess
          else exitFailure
      RunOn {} -> do
        params <- azureParameters (azureOptions cmd) (Just (sshOptions cmd))
        backend <- initializeBackend params
        css <- cloudServices backend
        forM_ (findTarget (target cmd) css) $ \vm -> do
          putStr (vmName vm ++ ": ") >> hFlush stdout 
          runOnVM backend vm (port cmd) ($(mkClosure 'cprint) "Hello world") 
      OnVmCommand (vmCmd@OnVmRun {}) -> do
        let rtable = __remoteTable initRemoteTable
        onVmRun rtable (onVmIP vmCmd) (onVmPort vmCmd)
    SSH.exit
  where
    opts = info (helper <*> commandParser)
      ( fullDesc 
      & header "Cloud Haskell backend for Azure"
      )

findTarget :: Target -> [CloudService] -> [VirtualMachine]
findTarget (CloudService cs) css = 
  concatMap cloudServiceVMs . filter ((== cs) . cloudServiceName) $ css
findTarget (VirtualMachine virtualMachine) css =
  [ vm | vm <- concatMap cloudServiceVMs css
       , vmName vm == virtualMachine
  ]

azureParameters :: AzureOptions -> Maybe SshOptions -> IO AzureParameters
azureParameters opts Nothing = 
  defaultAzureParameters (subscriptionId opts)
                         (pathToCert opts)
                         (pathToKey opts)
azureParameters opts (Just sshOpts) = do
  params <- defaultAzureParameters (subscriptionId opts)
                         (pathToCert opts)
                         (pathToKey opts)
  return params { 
      azureSshUserName = remoteUser sshOpts
    }

onVmRun :: RemoteTable -> String -> String -> IO ()
onVmRun rtable host port = do
  hSetBinaryMode stdin True
  proc <- BSL.getContents :: IO BSL.ByteString
  putStrLn $ "Got closure encoding of length " ++ show (BSL.length proc)
  mTransport <- createTransport host port defaultTCPParameters 
  case mTransport of
    Left err -> throwIO err
    Right transport -> do
      node <- newLocalNode transport rtable
      runProcess node $ do
        liftIO $ putStrLn "Starting remote node"
        catch (join . unClosure . decode $ proc) (\e -> liftIO $ print (e :: SomeException))
  
--------------------------------------------------------------------------------
-- Command line options                                                       --
--------------------------------------------------------------------------------

data AzureOptions = AzureOptions {
    subscriptionId :: String
  , pathToCert     :: FilePath
  , pathToKey      :: FilePath
  }
  deriving Show

data SshOptions = SshOptions {
    remoteUser :: String
  }
  deriving Show

data Target = 
    VirtualMachine String 
  | CloudService String
  deriving Show

data Command = 
    List { 
        azureOptions   :: AzureOptions 
      }
  | CopyTo { 
        azureOptions   :: AzureOptions 
      , sshOptions     :: SshOptions 
      , target         :: Target 
      }
  | CheckMD5 {
        azureOptions   :: AzureOptions
      , sshOptions     :: SshOptions 
      , target         :: Target 
      , status         :: Bool
      } 
  | RunOn { 
        azureOptions   :: AzureOptions 
      , sshOptions     :: SshOptions 
      , target         :: Target 
      , port           :: String 
      }
  | OnVmCommand {
        onVmCommand    :: OnVmCommand
      }
  deriving Show

data OnVmCommand =
    OnVmRun {
      onVmIP   :: String
    , onVmPort :: String
    }
  deriving Show

azureOptionsParser :: Parser AzureOptions
azureOptionsParser = AzureOptions 
  <$> strOption ( long "subscription-id"
                & metavar "SID" 
                & help "Azure subscription ID"
                )
  <*> strOption ( long "certificate"
                & metavar "CERT"
                & help "X509 certificate"
                )
  <*> strOption ( long "private"
                & metavar "PRI"
                & help "Private key in PKCS#1 format"
                )

sshOptionsParser :: Parser SshOptions
sshOptionsParser = SshOptions 
  <$> strOption ( long "user"
                & metavar "USER"
                & help "Remove SSH username"
                )

listParser :: Parser Command
listParser = List <$> azureOptionsParser

copyToParser :: Parser Command
copyToParser = CopyTo 
  <$> azureOptionsParser
  <*> sshOptionsParser
  <*> targetParser

targetParser :: Parser Target
targetParser = 
    ( VirtualMachine <$> strOption ( long "virtual-machine"
                                   & metavar "VM"
                                   & help "Virtual machine name"
                                   )
    )
  <|>
    ( CloudService   <$> strOption ( long "cloud-service"
                                   & metavar "CS"
                                   & help "Cloud service name"
                                   )
    )

checkMD5Parser :: Parser Command
checkMD5Parser = CheckMD5 
  <$> azureOptionsParser
  <*> sshOptionsParser
  <*> targetParser 
  <*> switch ( long "status"
             & help "Don't output anything, status code shows success"
             )

commandParser :: Parser Command
commandParser = subparser
  ( command "list"  (info listParser 
      (progDesc "List Azure cloud services"))
  & command "install" (info copyToParser
      (progDesc "Install the executable"))
  & command "md5" (info checkMD5Parser 
      (progDesc "Check if the remote and local MD5 hash match"))
  & command "run" (info runOnParser
      (progDesc "Run the executable"))
  & command "onvm" (info onVmCommandParser
      (progDesc "Commands used when running ON the vm (usually used internally only)"))
  )

runOnParser :: Parser Command
runOnParser = RunOn 
  <$> azureOptionsParser
  <*> sshOptionsParser
  <*> targetParser 
  <*> strOption ( long "port"
                & metavar "PORT"
                & help "Port number of the CH instance"
                )

onVmRunParser :: Parser OnVmCommand
onVmRunParser = OnVmRun 
  <$> strOption ( long "host"
                & metavar "IP"
                & help "IP address"
                )
  <*> strOption ( long "port"
                & metavar "PORT"
                & help "port number"
                )

onVmCommandParser :: Parser Command
onVmCommandParser = OnVmCommand <$> subparser
  ( command "run" (info onVmRunParser
      (progDesc "Run the executable"))
  )

