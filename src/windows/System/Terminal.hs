{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module System.Terminal
( fixCodePage
, hIsTerminalDeviceOrMinTTY
) where

import Distribution.Types.Version (mkVersion)
import Stack.Prelude
import System.Win32 (isMinTTYHandle, withHandleToHANDLE)
import System.Win32.Console (setConsoleCP, setConsoleOutputCP, getConsoleCP, getConsoleOutputCP)
import System.Console.Terminal.Common

import Control.Monad
import Data.Word
import Foreign.Ptr
import Foreign.Storable
import Foreign.Marshal.Alloc
import System.Exit
import System.IO
import System.Process

type HANDLE = Ptr ()

data CONSOLE_SCREEN_BUFFER_INFO

sizeCONSOLE_SCREEN_BUFFER_INFO :: Int
sizeCONSOLE_SCREEN_BUFFER_INFO = 22

posCONSOLE_SCREEN_BUFFER_INFO_srWindow :: Int
posCONSOLE_SCREEN_BUFFER_INFO_srWindow = 10 -- 4 x Word16 Left,Top,Right,Bottom

c_STD_OUTPUT_HANDLE :: Word32
c_STD_OUTPUT_HANDLE = -11

foreign import stdcall unsafe "windows.h GetConsoleScreenBufferInfo"
    c_GetConsoleScreenBufferInfo :: HANDLE -> Ptr CONSOLE_SCREEN_BUFFER_INFO -> IO Bool

foreign import stdcall unsafe "windows.h GetStdHandle"
    c_GetStdHandle :: Word32 -> IO HANDLE


size :: Integral n => IO (Maybe (Window n))
size = do
    hdl <- c_GetStdHandle c_STD_OUTPUT_HANDLE
    allocaBytes sizeCONSOLE_SCREEN_BUFFER_INFO $ \p -> do
        b <- c_GetConsoleScreenBufferInfo hdl p
        if not b
            then do -- This could happen on Cygwin or MSYS
                let stty = (shell "stty size") {
                      std_in  = UseHandle stdin
                    , std_out = CreatePipe
                    }
                (_, mbStdout, _, rStty) <- createProcess stty
                exStty <- waitForProcess rStty
                case exStty of
                    ExitFailure _ -> return Nothing
                    ExitSuccess ->
                        maybe (return Nothing)
                              (\hSize -> do
                                  sizeStr <- hGetContents hSize
                                  let [r, c] = map read $ words sizeStr :: [Int]
                                  return $ Just $ Window (fromIntegral r) (fromIntegral c)
                              )
                              mbStdout
            else do
                [left,top,right,bottom] <- forM [0..3] $ \i -> do
                    v <- peekByteOff p ((i*2) + posCONSOLE_SCREEN_BUFFER_INFO_srWindow)
                    return $ fromIntegral (v :: Word16)
                return $ Just $ Window (1+bottom-top) (1+right-left)

-- | Set the code page for this process as necessary. Only applies to Windows.
-- See: https://github.com/commercialhaskell/stack/issues/738
fixCodePage
  :: HasLogFunc env
  => Bool -- ^ modify code page?
  -> Version -- ^ GHC version
  -> RIO env a
  -> RIO env a
fixCodePage mcp ghcVersion inner = do
    if mcp && ghcVersion < mkVersion [7, 10, 3]
        then fixCodePage'
        -- GHC >=7.10.3 doesn't need this code page hack.
        else inner
  where
    fixCodePage' = do
        origCPI <- liftIO getConsoleCP
        origCPO <- liftIO getConsoleOutputCP

        let setInput = origCPI /= expected
            setOutput = origCPO /= expected
            fixInput
                | setInput = bracket_
                    (liftIO $ do
                        setConsoleCP expected)
                    (liftIO $ setConsoleCP origCPI)
                | otherwise = id
            fixOutput
                | setOutput = bracket_
                    (liftIO $ do
                        setConsoleOutputCP expected)
                    (liftIO $ setConsoleOutputCP origCPO)
                | otherwise = id

        case (setInput, setOutput) of
            (False, False) -> return ()
            (True, True) -> warn ""
            (True, False) -> warn " input"
            (False, True) -> warn " output"

        fixInput $ fixOutput inner
    expected = 65001 -- UTF-8
    warn typ = logInfo $
        "Setting" <>
        typ <>
        " codepage to UTF-8 (65001) to ensure correct output from GHC"

-- | hIsTerminaDevice does not recognise handles to mintty terminals as terminal
-- devices, but isMinTTYHandle does.
hIsTerminalDeviceOrMinTTY :: MonadIO m => Handle -> m Bool
hIsTerminalDeviceOrMinTTY h = do
  isTD <- hIsTerminalDevice h
  if isTD
    then return True
    else liftIO $ withHandleToHANDLE h isMinTTYHandle
