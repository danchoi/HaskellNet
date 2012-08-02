{-# LANGUAGE ScopedTypeVariables #-}
module Network.HaskellNet.SMTP
    ( -- * Types
      Command(..)
    , Response(..)
    , SMTPConnection
      -- * Establishing Connection
    , connectSMTPPort
    , connectSMTP
    , connectStream
      -- * Operation to a Connection
    , sendCommand
    , closeSMTP
      -- * Other Useful Operations 
    , sendMail
    , doSMTPPort
    , doSMTP
    , doSMTPStream
    , sendMimeMail
    )
    where

import Network.HaskellNet.BSStream
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Network.BSD (getHostName)
import Network

import Control.Exception
import Control.Monad (unless)

import Data.Char (isDigit)

import Network.HaskellNet.Auth

import System.IO

import Network.Mail.Mime
import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString as S

import qualified Data.Text.Lazy as LT
import qualified Data.Text as T

import Prelude hiding (catch)

data (BSStream s) => SMTPConnection s = SMTPC !s ![ByteString]

data Command = HELO String
             | EHLO String
             | MAIL String
             | RCPT String
             | DATA ByteString
             | EXPN String
             | VRFY String
             | HELP String
             | AUTH AuthType UserName Password
             | NOOP
             | RSET
             | QUIT
               deriving (Show, Eq)

type ReplyCode = Int

data Response = Ok
              | SystemStatus
              | HelpMessage
              | ServiceReady
              | ServiceClosing
              | UserNotLocal
              | CannotVerify
              | StartMailInput
              | ServiceNotAvailable
              | MailboxUnavailable
              | ErrorInProcessing
              | InsufficientSystemStorage
              | SyntaxError
              | ParameterError
              | CommandNotImplemented
              | BadSequence
              | ParameterNotImplemented
              | MailboxUnavailableError
              | UserNotLocalError
              | ExceededStorage
              | MailboxNotAllowed
              | TransactionFailed
                deriving (Show, Eq)

-- | connecting SMTP server with the specified name and port number.
connectSMTPPort :: String     -- ^ name of the server
                -> PortNumber -- ^ port number
                -> IO (SMTPConnection Handle)
connectSMTPPort hostname port =
    connectTo hostname (PortNumber port) >>= connectStream

-- | connecting SMTP server with the specified name and port 25.
connectSMTP :: String     -- ^ name of the server
            -> IO (SMTPConnection Handle)
connectSMTP = flip connectSMTPPort 25

tryCommand :: BSStream s => s -> Command -> Int -> ReplyCode
           -> IO ByteString
tryCommand st cmd tries expectedReply | tries <= 0 = do
  bsClose st
  fail $ "cannot execute command " ++ show cmd ++
           ", expected reply code " ++ show expectedReply
tryCommand st cmd tries expectedReply = do
  (code, msg) <- sendCommand (SMTPC st []) cmd
  if code == expectedReply then
      return msg else
      tryCommand st cmd (tries - 1) expectedReply

-- | create SMTPConnection from already connected Stream
connectStream :: BSStream s => s -> IO (SMTPConnection s)
connectStream st =
    do (code1, _) <- parseResponse st
       unless (code1 == 220) $
              do bsClose st
                 fail "cannot connect to the server"
       senderHost <- getHostName
       msg <- tryCommand st (EHLO senderHost) 3 250
       return (SMTPC st (tail $ BS.lines msg))

parseResponse :: BSStream s => s -> IO (ReplyCode, ByteString)
parseResponse st =
    do (code, bdy) <- readLines
       return (read $ BS.unpack code, BS.unlines bdy)
    where readLines =
              do l <- bsGetLine st
                 let (c, bdy) = BS.span isDigit l
                 if not (BS.null bdy) && BS.head bdy == '-'
                    then do (c2, ls) <- readLines
                            return (c2, (BS.tail bdy:ls))
                    else return (c, [BS.tail bdy])


-- | send a method to a server
sendCommand :: BSStream s => SMTPConnection s -> Command
            -> IO (ReplyCode, ByteString)
sendCommand (SMTPC conn _) (DATA dat) =
    do bsPutCrLf conn $ BS.pack "DATA"
       (code, _) <- parseResponse conn
       unless (code == 354) $ fail "this server cannot accept any data."
       mapM_ sendLine $ BS.lines dat ++ [BS.pack "."]
       parseResponse conn
    where sendLine l = bsPutCrLf conn l
sendCommand (SMTPC conn _) (AUTH LOGIN username password) =
    do bsPutCrLf conn command
       (_, _) <- parseResponse conn
       bsPutCrLf conn $ BS.pack userB64
       (_, _) <- parseResponse conn
       bsPutCrLf conn $ BS.pack passB64
       parseResponse conn
    where command = BS.pack $ "AUTH LOGIN"
          (userB64, passB64) = login username password
sendCommand (SMTPC conn _) (AUTH at username password) =
    do bsPutCrLf conn command
       (code, msg) <- parseResponse conn
       unless (code == 334) $ fail "authentication failed."
       bsPutCrLf conn $ BS.pack $ auth at (BS.unpack msg) username password
       parseResponse conn
    where command = BS.pack $ unwords ["AUTH", show at]
sendCommand (SMTPC conn _) meth =
    do bsPutCrLf conn $ BS.pack command
       parseResponse conn
    where command = case meth of
                      (HELO param) -> "HELO " ++ param
                      (EHLO param) -> "EHLO " ++ param
                      (MAIL param) -> "MAIL FROM:<" ++ param ++ ">"
                      (RCPT param) -> "RCPT TO:<" ++ param ++ ">"
                      (EXPN param) -> "EXPN " ++ param
                      (VRFY param) -> "VRFY " ++ param
                      (HELP msg)   -> if null msg
                                        then "HELP\r\n"
                                        else "HELP " ++ msg
                      NOOP         -> "NOOP"
                      RSET         -> "RSET"
                      QUIT         -> "QUIT"
                      (DATA _)     ->
                          error "BUG: DATA pattern should be matched by sendCommand patterns"
                      (AUTH _ _ _)     ->
                          error "BUG: AUTH pattern should be matched by sendCommand patterns"

-- | close the connection.  This function send the QUIT method, so you
-- do not have to QUIT method explicitly.
closeSMTP :: BSStream s => SMTPConnection s -> IO ()
closeSMTP (SMTPC conn _) = bsClose conn

{-
I must be being stupid here

I can't seem to be able to catch the exception arising from the
connection already being closed this would be the correct way to do it
but instead we're being naughty above by just closes the connection
without first sending QUIT

closeSMTP c@(SMTPC conn _) =
    do sendCommand c QUIT
       bsClose conn `catch` \(_ :: IOException) -> return ()
-}

-- | sending a mail to a server. This is achieved by sendMessage.  If
-- something is wrong, it raises an IOexception.
sendMail :: BSStream s =>
            String     -- ^ sender mail
         -> [String]   -- ^ receivers
         -> ByteString -- ^ data
         -> SMTPConnection s
         -> IO ()
sendMail sender receivers dat conn =
    catcher `handle` mainProc
    where mainProc =
              do (250, _) <- sendCommand conn (MAIL sender)
                 vals <- mapM (sendCommand conn . RCPT) receivers
                 unless (all ((==250) . fst) vals) $ fail "sendMail error"
                 (250, _) <- sendCommand conn (DATA dat)
                 return ()
          catcher e@(PatternMatchFail _) = throwIO e

-- | doSMTPPort open a connection, and do an IO action with the
-- connection, and then close it.
doSMTPPort :: String -> PortNumber -> (SMTPConnection Handle -> IO a) -> IO a
doSMTPPort host port execution =
    bracket (connectSMTPPort host port) closeSMTP execution

-- | doSMTP is similar to doSMTPPort, except that it does not require
-- port number but connects to the server with port 25.
doSMTP :: String -> (SMTPConnection Handle -> IO a) -> IO a
doSMTP host execution = doSMTPPort host 25 execution

-- | doSMTPStream is similar to doSMTPPort, except that its argument
-- is a Stream data instead of hostname and port number.
doSMTPStream :: BSStream s => s -> (SMTPConnection s -> IO a) -> IO a
doSMTPStream s execution = bracket (connectStream s) closeSMTP execution

sendMimeMail :: BSStream s => String -> String -> String -> LT.Text
             -> LT.Text -> [(T.Text, FilePath)] -> SMTPConnection s -> IO ()
sendMimeMail to from subject plainBody htmlBody attachments con = do
  myMail <- simpleMail (T.pack to) (T.pack from) (T.pack subject)
            plainBody htmlBody attachments
  renderedMail <- renderMail' myMail
  sendMail from [to] (lazyToStrict renderedMail) con
  closeSMTP con

-- haskellNet uses strict bytestrings
-- TODO: look at making haskellnet lazy
lazyToStrict :: B.ByteString -> S.ByteString
lazyToStrict = S.concat . B.toChunks

