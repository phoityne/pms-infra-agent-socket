{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}

module PMS.Infra.Agent.Socket.App.ControlSpec (spec) where

import Test.Hspec
import Control.Concurrent.Async
import qualified Control.Concurrent.STM as STM
import Control.Lens
import Data.Default
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory
import System.FilePath
import System.IO
import Network.Socket
import Network.Socket.ByteString (recv)
import System.Log.FastLogger
import qualified System.Log.FastLogger as FastLogger

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Infra.Agent.Socket.App.Control as SUT
import qualified PMS.Infra.Agent.Socket.DM.Type as SUT
import qualified PMS.Infra.Agent.Socket.DS.Core as Core
import qualified PMS.Infra.Agent.Socket.DS.Utility as Util

-- |
--
data SpecContext = SpecContext {
                   _domainDataSpecContext :: DM.DomainData
                 , _appDataSpecContext :: SUT.AppData
                 }

makeLenses ''SpecContext

defaultSpecContext :: IO SpecContext
defaultSpecContext = do
  domDat <- DM.defaultDomainData
  appDat <- SUT.defaultAppData
  return SpecContext {
           _domainDataSpecContext = domDat
         , _appDataSpecContext    = appDat
         }

-- |
--
spec :: Spec
spec = do
  runIO $ putStrLn "Start Spec."
  beforeAll setUpOnce $
    afterAll tearDownOnce .
      beforeWith setUp .
        after tearDown $ run

-- |
--
setUpOnce :: IO SpecContext
setUpOnce = do
  putStrLn "[INFO] EXECUTED ONLY ONCE BEFORE ALL TESTS START."
  defaultSpecContext

-- |
--
tearDownOnce :: SpecContext -> IO ()
tearDownOnce _ = do
  putStrLn "[INFO] EXECUTED ONLY ONCE AFTER ALL TESTS FINISH."

-- |
--
setUp :: SpecContext -> IO SpecContext
setUp ctx = do
  putStrLn "[INFO] EXECUTED BEFORE EACH TEST STARTS."
  domDat <- DM.defaultDomainData
  appDat <- SUT.defaultAppData
  return ctx {
               _domainDataSpecContext = domDat
             , _appDataSpecContext    = appDat
             }

-- |
--
tearDown :: SpecContext -> IO ()
tearDown _ = do
  putStrLn "[INFO] EXECUTED AFTER EACH TEST FINISHES."

-- |
--
run :: SpecWith SpecContext
run = do
  describe "runWithAppData" $ do
    context "when echo command issued." $ do
      it "should call callback" $ \ctx -> do
        putStrLn "[INFO] EXECUTING THE FIRST TEST."

        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            cmdQ   = domDat^.DM.agentSocketQueueDomainData
            resQ   = domDat^.DM.responseQueueDomainData
            expect = "abc"
            jsonR  = def {DM._jsonrpcJsonRpcRequest = expect}
            argDat = DM.AgentSocketEchoCommandData jsonR expect
            args   = DM.AgentSocketEchoCommand argDat

        thId <- async $ SUT.runWithAppData appDat domDat

        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let actual = dat^.DM.jsonrpcMcpToolsCallResponseData^.DM.jsonrpcJsonRpcRequest
        actual `shouldBe` expect

        cancel thId

  ---------------------------------------------------------------------------
  -- CR-06: agent-socket-read / agent-socket-read-byte
  ---------------------------------------------------------------------------

  describe "TC-06-01: read without open" $ do
    context "when handleAppData is Nothing" $ do
      it "should return isError=True" $ \ctx -> do
        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            cmdDat = DM.AgentSocketReadCommandData
                       { DM._jsonrpcAgentSocketReadCommandData   = mkJsonRpc "agent-socket-read"
                       , DM._argumentsAgentSocketReadCommandData = DM.RawJsonByteString ""
                       }
        Core.socketReadTask cmdDat
                            (domDat^.DM.responseQueueDomainData)
                            (appDat^.SUT.handleAppData)
                            16
        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue (domDat^.DM.responseQueueDomainData)
        isError dat `shouldBe` True
        firstContentText dat  `shouldBe` ""
        secondContentText dat `shouldBe` "socket is not connected."

  describe "TC-06-02: read returns UTF-8 string" $ do
    context "when handle has UTF-8 bytes" $ do
      it "should decode bytes as UTF-8 string" $ \ctx -> do
        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            payload = TE.encodeUtf8 $ T.pack "hello-\26085\26412\35486"
            cmdDat = DM.AgentSocketReadCommandData
                       { DM._jsonrpcAgentSocketReadCommandData   = mkJsonRpc "agent-socket-read"
                       , DM._argumentsAgentSocketReadCommandData = DM.RawJsonByteString ""
                       }
        withReadHandle "pms-agent-socket-read-utf8.txt" payload $ \hdl -> do
          _ <- STM.atomically $ STM.swapTMVar (appDat^.SUT.handleAppData) (Just hdl)
          Core.socketReadTask cmdDat
                              (domDat^.DM.responseQueueDomainData)
                              (appDat^.SUT.handleAppData)
                              64
          (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue (domDat^.DM.responseQueueDomainData)
          isError dat `shouldBe` False
          firstContentText dat `shouldBe` "hello-\26085\26412\35486"

  describe "TC-06-03: read-byte returns hex string" $ do
    context "when handle has binary bytes" $ do
      it "should encode bytes as uppercase hex string" $ \ctx -> do
        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            payload = BS.pack [0x00, 0x0A, 0x1B, 0xFF]
            cmdDat = DM.AgentSocketReadByteCommandData
                       { DM._jsonrpcAgentSocketReadByteCommandData   = mkJsonRpc "agent-socket-read-byte"
                       , DM._argumentsAgentSocketReadByteCommandData = DM.RawJsonByteString ""
                       }
        withReadHandle "pms-agent-socket-read-byte.bin" payload $ \hdl -> do
          _ <- STM.atomically $ STM.swapTMVar (appDat^.SUT.handleAppData) (Just hdl)
          Core.socketReadByteTask cmdDat
                                  (domDat^.DM.responseQueueDomainData)
                                  (appDat^.SUT.handleAppData)
                                  4
          (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue (domDat^.DM.responseQueueDomainData)
          isError dat `shouldBe` False
          firstContentText dat `shouldBe` "000A1BFF"

  describe "TC-06-04: read timeout or no data" $ do
    context "when handle has no data" $ do
      it "should return success with empty text" $ \ctx -> do
        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            cmdDat = DM.AgentSocketReadCommandData
                       { DM._jsonrpcAgentSocketReadCommandData   = mkJsonRpc "agent-socket-read"
                       , DM._argumentsAgentSocketReadCommandData = DM.RawJsonByteString ""
                       }
        withEmptySocketHandle $ \hdl -> do
          _ <- STM.atomically $ STM.swapTMVar (appDat^.SUT.handleAppData) (Just hdl)
          Core.socketReadTask cmdDat
                              (domDat^.DM.responseQueueDomainData)
                              (appDat^.SUT.handleAppData)
                              16
          (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue (domDat^.DM.responseQueueDomainData)
          isError dat `shouldBe` False
          firstContentText dat `shouldBe` ""

  ---------------------------------------------------------------------------
  -- CR-07: agent-socket-write / agent-socket-write-byte
  ---------------------------------------------------------------------------

  describe "TC-07-01: write without open" $ do
    context "when handleAppData is Nothing" $ do
      it "should return isError=True with 'socket is not connected.'" $ \ctx -> do
        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            cmdDat = DM.AgentSocketWriteCommandData
                       { DM._jsonrpcAgentSocketWriteCommandData   = mkJsonRpc "agent-socket-write"
                       , DM._argumentsAgentSocketWriteCommandData = DM.RawJsonByteString ""
                       }
        Core.socketWriteTask cmdDat
                             (domDat^.DM.responseQueueDomainData)
                             (appDat^.SUT.handleAppData)
                             "hello"
                             Nothing
        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue (domDat^.DM.responseQueueDomainData)
        isError dat `shouldBe` True
        secondContentText dat `shouldBe` "socket is not connected."

  describe "TC-07-02: write UTF-8 string" $ do
    context "when socket is connected and data is a UTF-8 string" $ do
      it "should write UTF-8 encoded bytes to the server side" $ \ctx -> do
        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            str    = "hello-\26085\26412\35486"
            expect = TE.encodeUtf8 (T.pack str)
            cmdDat = DM.AgentSocketWriteCommandData
                       { DM._jsonrpcAgentSocketWriteCommandData   = mkJsonRpc "agent-socket-write"
                       , DM._argumentsAgentSocketWriteCommandData = DM.RawJsonByteString ""
                       }
        withConnectedPair $ \clientHdl serverSock -> do
          _ <- STM.atomically $ STM.swapTMVar (appDat^.SUT.handleAppData) (Just clientHdl)
          Core.socketWriteTask cmdDat
                               (domDat^.DM.responseQueueDomainData)
                               (appDat^.SUT.handleAppData)
                               str
                               (Just False)
          (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue (domDat^.DM.responseQueueDomainData)
          isError dat `shouldBe` False
          received <- recv serverSock (BS.length expect + 16)
          received `shouldBe` expect

  describe "TC-07-03: write-byte uppercase hex string" $ do
    context "when data is uppercase hex string" $ do
      it "should write decoded bytes to the server side" $ \ctx -> do
        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            hex    = "000A1BFF"
            expect = BS.pack [0x00, 0x0A, 0x1B, 0xFF]
            cmdDat = DM.AgentSocketWriteByteCommandData
                       { DM._jsonrpcAgentSocketWriteByteCommandData   = mkJsonRpc "agent-socket-write-byte"
                       , DM._argumentsAgentSocketWriteByteCommandData = DM.RawJsonByteString ""
                       }
        Right bs <- return $ Util.hexToBytes hex
        withConnectedPair $ \clientHdl serverSock -> do
          _ <- STM.atomically $ STM.swapTMVar (appDat^.SUT.handleAppData) (Just clientHdl)
          Core.socketWriteByteTask cmdDat
                                   (domDat^.DM.responseQueueDomainData)
                                   (appDat^.SUT.handleAppData)
                                   bs
          (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue (domDat^.DM.responseQueueDomainData)
          isError dat `shouldBe` False
          received <- recv serverSock 16
          received `shouldBe` expect

  describe "TC-07-04: write-byte lowercase/mixed-case hex string" $ do
    context "when data is lowercase or mixed-case hex string" $ do
      it "should write correctly decoded bytes to the server side" $ \ctx -> do
        let domDat = ctx^.domainDataSpecContext
            expect = BS.pack [0x00, 0x0A, 0x1B, 0xFF]
            hexes  = ["000a1bff", "000a1BFF"]
            cmdDat = DM.AgentSocketWriteByteCommandData
                       { DM._jsonrpcAgentSocketWriteByteCommandData   = mkJsonRpc "agent-socket-write-byte"
                       , DM._argumentsAgentSocketWriteByteCommandData = DM.RawJsonByteString ""
                       }
        mapM_ (\hex -> do
          Right bs <- return $ Util.hexToBytes hex
          appDat' <- SUT.defaultAppData
          withConnectedPair $ \clientHdl serverSock -> do
            _ <- STM.atomically $ STM.swapTMVar (appDat'^.SUT.handleAppData) (Just clientHdl)
            Core.socketWriteByteTask cmdDat
                                     (domDat^.DM.responseQueueDomainData)
                                     (appDat'^.SUT.handleAppData)
                                     bs
            (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue (domDat^.DM.responseQueueDomainData)
            isError dat `shouldBe` False
            received <- recv serverSock 16
            received `shouldBe` expect
          ) hexes

  describe "TC-07-05: write-byte invalid hex string" $ do
    context "when hex string contains non-hex characters" $ do
      it "should return Left with hexToBytes error in AppContext" $ \ctx -> do
        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            argsJson = "{\"data\":\"ZZZZ\"}"
            cmdDat = DM.AgentSocketWriteByteCommandData
                       { DM._jsonrpcAgentSocketWriteByteCommandData   = mkJsonRpc "agent-socket-write-byte"
                       , DM._argumentsAgentSocketWriteByteCommandData = DM.RawJsonByteString argsJson
                       }
        withStderrLogger $ \logger -> do
          result <- Util.runApp domDat appDat logger (Core.genSocketWriteByteTask cmdDat)
          case result of
            Left errMsg -> errMsg `shouldContain` "hexToBytes"
            Right _     -> expectationFailure "Expected Left (hexToBytes error) but got Right"

  ---------------------------------------------------------------------------
  -- TC-A: agent-socket-write — appendNewline default (omitted) appends \n
  ---------------------------------------------------------------------------
  describe "TC-A: agent-socket-write appendNewline default appends newline" $ do
    context "when appendNewline is Nothing (default True) and input has no trailing newline" $ do
      it "should append \\n to the transmitted bytes" $ \ctx -> do
        putStrLn "[INFO] TC-A start."
        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            str    = "hello"
            expect = TE.encodeUtf8 (T.pack (str ++ nativeLineEnding))
            cmdDat = DM.AgentSocketWriteCommandData
                       { DM._jsonrpcAgentSocketWriteCommandData   = mkJsonRpc "agent-socket-write"
                       , DM._argumentsAgentSocketWriteCommandData = DM.RawJsonByteString ""
                       }
        withConnectedPair $ \clientHdl serverSock -> do
          _ <- STM.atomically $ STM.swapTMVar (appDat^.SUT.handleAppData) (Just clientHdl)
          Core.socketWriteTask cmdDat
                               (domDat^.DM.responseQueueDomainData)
                               (appDat^.SUT.handleAppData)
                               str
                               Nothing
          (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue (domDat^.DM.responseQueueDomainData)
          isError dat `shouldBe` False
          received <- recv serverSock (BS.length expect + 4)
          received `shouldBe` expect

  ---------------------------------------------------------------------------
  -- TC-B: agent-socket-write — appendNewline=False suppresses newline
  ---------------------------------------------------------------------------
  describe "TC-B: agent-socket-write appendNewline=False suppresses newline" $ do
    context "when appendNewline is Just False" $ do
      it "should NOT append \\n; transmitted bytes equal raw input" $ \ctx -> do
        putStrLn "[INFO] TC-B start."
        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            str    = "hello"
            expect = TE.encodeUtf8 (T.pack str)  -- no newline
            cmdDat = DM.AgentSocketWriteCommandData
                       { DM._jsonrpcAgentSocketWriteCommandData   = mkJsonRpc "agent-socket-write"
                       , DM._argumentsAgentSocketWriteCommandData = DM.RawJsonByteString ""
                       }
        withConnectedPair $ \clientHdl serverSock -> do
          _ <- STM.atomically $ STM.swapTMVar (appDat^.SUT.handleAppData) (Just clientHdl)
          Core.socketWriteTask cmdDat
                               (domDat^.DM.responseQueueDomainData)
                               (appDat^.SUT.handleAppData)
                               str
                               (Just False)
          (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue (domDat^.DM.responseQueueDomainData)
          isError dat `shouldBe` False
          received <- recv serverSock (BS.length expect + 4)
          received `shouldBe` expect

  ---------------------------------------------------------------------------
  -- CR-12: invalidPatterns / sandboxNetworks tests
  ---------------------------------------------------------------------------

  -- TC-08: invalidPatterns - matching input -> isError=True (via runWithAppData)
  describe "TC-08: invalidPatterns - matching input is rejected" $ do
    context "when agent-socket-write input matches an invalidPatterns entry" $ do
      it "should return isError=True" $ \_ -> do
        putStrLn "[INFO] TC-08 start."
        domDat <- DM.defaultDomainData
        let domDat' = domDat { DM._invalidPatternsDomainData = ["rm", "shutdown"] }
        appDat <- SUT.defaultAppData
        thId   <- async $ SUT.runWithAppData appDat domDat'
        let cmdQ = domDat'^.DM.agentSocketQueueDomainData
            resQ = domDat'^.DM.responseQueueDomainData
            argsJson = "{\"data\":\"rm -rf /\"}"
            cmdDat = DM.AgentSocketWriteCommandData
                       { DM._jsonrpcAgentSocketWriteCommandData   = mkJsonRpc "agent-socket-write"
                       , DM._argumentsAgentSocketWriteCommandData = DM.RawJsonByteString argsJson
                       }
        STM.atomically $ STM.writeTQueue cmdQ (DM.AgentSocketWriteCommand cmdDat)
        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ
        isError dat `shouldBe` True
        cancel thId

  -- TC-09: invalidPatterns - non-matching input is allowed (via runWithAppData)
  describe "TC-09: invalidPatterns - non-matching input is allowed" $ do
    context "when agent-socket-write input does NOT match any invalidPatterns entry" $ do
      it "should return isError=False when socket is connected" $ \_ -> do
        putStrLn "[INFO] TC-09 start."
        domDat <- DM.defaultDomainData
        let domDat' = domDat { DM._invalidPatternsDomainData = ["rm", "shutdown"] }
        appDat <- SUT.defaultAppData
        thId   <- async $ SUT.runWithAppData appDat domDat'
        withConnectedPair $ \clientHdl _serverSock -> do
          _ <- STM.atomically $ STM.swapTMVar (appDat^.SUT.handleAppData) (Just clientHdl)
          let cmdQ = domDat'^.DM.agentSocketQueueDomainData
              resQ = domDat'^.DM.responseQueueDomainData
              argsJson = "{\"data\":\"echo hello\"}"
              cmdDat = DM.AgentSocketWriteCommandData
                         { DM._jsonrpcAgentSocketWriteCommandData   = mkJsonRpc "agent-socket-write"
                         , DM._argumentsAgentSocketWriteCommandData = DM.RawJsonByteString argsJson
                         }
          STM.atomically $ STM.writeTQueue cmdQ (DM.AgentSocketWriteCommand cmdDat)
          (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ
          isError dat `shouldBe` False
        cancel thId

  -- TC-10: sandboxNetworks - empty list -> TCP open is rejected
  describe "TC-10: sandboxNetworks - empty list denies all TCP connections" $ do
    context "when sandboxNetworks is empty and TCP open is attempted" $ do
      it "should return Left (connection refused)" $ \_ -> do
        putStrLn "[INFO] TC-10 start."
        domDat <- DM.defaultDomainData
        let domDat' = domDat { DM._sandboxNetworksDomainData = [] }
        appDat <- SUT.defaultAppData
        let argsJson = "{\"host\":\"127.0.0.1\",\"port\":\"9999\"}"
            cmdDat = def
                       { DM._jsonrpcAgentSocketOpenCommandData   = mkJsonRpc "agent-socket-open"
                       , DM._argumentsAgentSocketOpenCommandData = DM.RawJsonByteString argsJson
                       }
        withStderrLogger $ \logger -> do
          result <- Util.runApp domDat' appDat logger (Core.genSocketOpenTask cmdDat)
          case result of
            Left errMsg -> errMsg `shouldContain` "sandboxNetworks is empty"
            Right _     -> expectationFailure "Expected Left but got Right"

  -- TC-11: sandboxNetworks - IP within range -> gen succeeds
  describe "TC-11: sandboxNetworks - IP within range allows TCP open" $ do
    context "when sandboxNetworks contains 127.0.0.0/8 and host is 127.0.0.1" $ do
      it "should not be rejected by sandboxNetworks check" $ \_ -> do
        putStrLn "[INFO] TC-11 start."
        domDat <- DM.defaultDomainData
        let domDat' = domDat { DM._sandboxNetworksDomainData = ["127.0.0.0/8"] }
        appDat <- SUT.defaultAppData
        let argsJson = "{\"host\":\"127.0.0.1\",\"port\":\"9999\"}"
            cmdDat = def
                       { DM._jsonrpcAgentSocketOpenCommandData   = mkJsonRpc "agent-socket-open"
                       , DM._argumentsAgentSocketOpenCommandData = DM.RawJsonByteString argsJson
                       }
        withStderrLogger $ \logger -> do
          result <- Util.runApp domDat' appDat logger (Core.genSocketOpenTask cmdDat)
          case result of
            Left errMsg -> errMsg `shouldNotContain` "outside sandboxNetworks"
            Right _     -> return ()

  -- TC-12: sandboxNetworks - IP outside range -> rejected
  describe "TC-12: sandboxNetworks - IP outside range denies TCP open" $ do
    context "when sandboxNetworks contains only 10.0.0.0/8 and host is 127.0.0.1" $ do
      it "should return Left (outside sandboxNetworks)" $ \_ -> do
        putStrLn "[INFO] TC-12 start."
        domDat <- DM.defaultDomainData
        let domDat' = domDat { DM._sandboxNetworksDomainData = ["10.0.0.0/8"] }
        appDat <- SUT.defaultAppData
        let argsJson = "{\"host\":\"127.0.0.1\",\"port\":\"9999\"}"
            cmdDat = def
                       { DM._jsonrpcAgentSocketOpenCommandData   = mkJsonRpc "agent-socket-open"
                       , DM._argumentsAgentSocketOpenCommandData = DM.RawJsonByteString argsJson
                       }
        withStderrLogger $ \logger -> do
          result <- Util.runApp domDat' appDat logger (Core.genSocketOpenTask cmdDat)
          case result of
            Left errMsg -> errMsg `shouldContain` "outside sandboxNetworks"
            Right _     -> expectationFailure "Expected Left (sandboxNetworks check) but got Right"

  -- TC-13: sandboxNetworks - Unix Domain Socket is exempt
  describe "TC-13: sandboxNetworks - Unix Domain Socket bypasses sandboxNetworks check" $ do
    context "when sandboxNetworks is empty but file is specified" $ do
      it "gen should return Right (sandboxNetworks bypassed)" $ \_ -> do
        putStrLn "[INFO] TC-13 start."
        domDat <- DM.defaultDomainData
        let domDat' = domDat { DM._sandboxNetworksDomainData = [] }
        appDat <- SUT.defaultAppData
        let argsJson = "{\"file\":\"/tmp/nonexistent-pms-cr12-tc13.sock\"}"
            cmdDat = def
                       { DM._jsonrpcAgentSocketOpenCommandData   = mkJsonRpc "agent-socket-open"
                       , DM._argumentsAgentSocketOpenCommandData = DM.RawJsonByteString argsJson
                       }
        withStderrLogger $ \logger -> do
          result <- Util.runApp domDat' appDat logger (Core.genSocketOpenTask cmdDat)
          case result of
            Left errMsg -> expectationFailure $
              "Expected Right (sandboxNetworks bypassed) but got Left: " ++ errMsg
            Right _     -> return ()

---------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------

mkJsonRpc :: String -> DM.JsonRpcRequest
mkJsonRpc method = def { DM._methodJsonRpcRequest = method }

isError :: DM.McpToolsCallResponseData -> Bool
isError dat =
  dat^.DM.resultMcpToolsCallResponseData^.DM.isErrorMcpToolsCallResponseResult

firstContentText :: DM.McpToolsCallResponseData -> String
firstContentText dat =
  let contents = dat^.DM.resultMcpToolsCallResponseData^.DM.contentMcpToolsCallResponseResult
  in DM._textMcpToolsCallResponseResultContent (head contents)

secondContentText :: DM.McpToolsCallResponseData -> String
secondContentText dat =
  let contents = dat^.DM.resultMcpToolsCallResponseData^.DM.contentMcpToolsCallResponseResult
  in DM._textMcpToolsCallResponseResultContent (contents !! 1)

nativeLineEnding :: String
nativeLineEnding = case nativeNewline of
  CRLF -> "\r\n"
  LF   -> "\n"

withReadHandle :: FilePath -> BS.ByteString -> (Handle -> IO a) -> IO a
withReadHandle name content action = do
  tmpDir <- getTemporaryDirectory
  let path = tmpDir </> name
  BS.writeFile path content
  withBinaryFile path ReadMode action

withEmptySocketHandle :: (Handle -> IO a) -> IO a
withEmptySocketHandle action = do
  listener <- socket AF_INET Stream defaultProtocol
  bind listener (SockAddrInet defaultPort (tupleToHostAddress (127,0,0,1)))
  listen listener 1
  port <- socketPort listener
  client <- socket AF_INET Stream defaultProtocol
  connect client (SockAddrInet port (tupleToHostAddress (127,0,0,1)))
  (server, _) <- accept listener
  clientHdl <- socketToHandle client ReadWriteMode
  hSetBuffering clientHdl NoBuffering
  result <- action clientHdl
  hClose clientHdl
  close server
  close listener
  return result

withConnectedPair :: (Handle -> Socket -> IO a) -> IO a
withConnectedPair action = do
  listener <- socket AF_INET Stream defaultProtocol
  bind listener (SockAddrInet defaultPort (tupleToHostAddress (127,0,0,1)))
  listen listener 1
  port <- socketPort listener
  client <- socket AF_INET Stream defaultProtocol
  connect client (SockAddrInet port (tupleToHostAddress (127,0,0,1)))
  (server, _) <- accept listener
  clientHdl <- socketToHandle client ReadWriteMode
  hSetBuffering clientHdl NoBuffering
  result <- action clientHdl server
  hClose clientHdl
  close server
  close listener
  return result

withStderrLogger :: (FastLogger.TimedFastLogger -> IO a) -> IO a
withStderrLogger action = do
  tc <- newTimeCache "%Y-%m-%d %H:%M:%S"
  (logger, finalizer) <- newTimedFastLogger tc (LogStderr defaultBufSize)
  result <- action logger
  finalizer
  return result