{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DataKinds #-}

module Messenger.TG where

import           Logger                     (AppMonad, logDebug, logInfo, logWarning, logError)
import           Messenger.Proxy (proxyParser)
import           Network.HTTP.Simple
import           Data.Update
import           Messenger.Internal
import           Data.Aeson
import           Data.Aeson.Types
import           Control.Applicative        
import           Control.Monad 
import           Control.Monad.Reader
import           Data.Foldable               (asum)
import           Data.ByteString.Char8       (ByteString)
import           Data.Text.Encoding          (encodeUtf8)
import           Data.Text                   (Text)
import qualified Data.Vector           as V
import qualified Data.Text             as T
import qualified Data.ByteString.Char8.Extended as S8
import qualified Data.ByteString.Lazy.Char8 as L8
import           Data.Ini.Config

data Config = Config
  { token :: ByteString
  , proxy :: Maybe Proxy
  } deriving (Show)               

configParser :: IniParser Config
configParser = section "TG" $ do 
  token <- fieldOf "token" string
  proxy <- proxyParser
  return $ Config{..}

getConfig :: Text -> AppMonad Config
getConfig txt = do
  let eConfig = parseIniFile txt configParser
  case eConfig of
    Right cfg -> do logDebug "Messenger | Read TG config from file config.ini"
                    return cfg
    Left err  -> do logError $ unwords [ "Messenger | Couldn`t read TG config from file config.ini. Check it:", err]
                    error ""

withHandle :: Config -> (Handle -> AppMonad ()) -> AppMonad ()
withHandle cfg@Config{..} f = f Handle{..} where
  sendMessage :: UserId -> Content -> AppMonad ()
  sendMessage = sendMessageWith id
  
  sendKeyMessage :: Keyboard -> UserId -> Content -> AppMonad ()
  sendKeyMessage  = sendMessageWith . addToRequestQueryString . keyboardQuery
  
  getUpdate :: Int -> AppMonad [Update]
  getUpdate offset = do
    let req    = baseReqWith "GET" "/getUpdates" query
        query  = [("offset", Just $ S8.show offset), ("timeout", Just "25")]
    logDebug $ "Messenger | Sending request:" <> show req
    response <- httpLBS req
    logDebug $ "Messenger | Response received:" <> show response
    response <- httpLBS req
    let body   = getResponseBody response
        update = parseEither updateLstPars =<< eitherDecode body
    case update of
      Left err  -> do logDebug  "Messenger | There`s no updates"
                      logInfo $ "Messenger | " <> show err
                      return []
      Right lst -> do logDebug $ "Messenger | Updates received: " <> show lst
                      return lst

  baseReqWith :: ByteString -> ByteString -> Query -> Request
  baseReqWith method path query = setRequestMethod method
                                $ setRequestPath ("bot" <> token <> path)
                                $ addToRequestQueryString query
                                $ setRequestProxy proxy
                                "https://api.telegram.org"

  sendMessageWith :: (Request -> Request) -> UserId -> Content -> AppMonad ()
  sendMessageWith f userId cont = do
    logDebug  $ "Messenger | Sending request:" <> show req
    void $ httpLBS $ f req
    where postReqWith path (flag,txt) = baseReqWith "POST" path [("chat_id", Just $ S8.show userId), (flag, Just txt)]
          req = case cont of
                  (TextMsg t)      -> postReqWith "/sendMessage"   ("text", t)
                  (FileMsg t)      -> postReqWith "/sendDocument"  ("document", t)
                  (AudioMsg t)     -> postReqWith "/sendVoice"     ("voice", t)
                  (StickerMsg t)   -> postReqWith "/sendSticker"   ("sticker", t)
                  (AnimationMsg t) -> postReqWith "/sendAnimation" ("animation", t)
                  (PhotoMsg t)     -> postReqWith "/sendPhoto"     ("photo", t)
                  unsupported      -> error $ "Unsupported content type : " <> show unsupported

keyboardQuery :: Keyboard -> Query
keyboardQuery kb = [("reply_markup", Just . L8.toStrict . encode $ keyboard kb)]
  where keyboard :: Keyboard -> Value
        keyboard kb = object [ "inline_keyboard" .= (fmap.fmap) button kb]
        button :: Button -> Value
        button (label, value) = object [ "text" .= label
                                       , "callback_data" .= ("/setRepeat " <> value)
                                       ]


-- | This section voted to parsing Update value from response.

updateLstPars :: Pars [Update]
updateLstPars = withObject "[Update] with Bot.Impl.TG.updateLstPars" $ \o -> do
  vec <- o .: "result"
  mapM updatePars $ V.toList vec
    
updatePars :: Pars Update
updatePars = withObject "Update with Bot.Impl.TG.updatePars" $ \o -> do
    updateId <- (o .: "update_id") :: Parser Int
    message  <- o .: "message" <|> o .: "edited_message" <|> o .: "callback_query"
    userId   <- (message .: "from") >>= ( .: "id")
    content  <- asum [ commandPars (Object message)
                     , callbackPars (Object message)
                     , TextMsg . encodeUtf8 <$> (message .: "text")
                     , AudioMsg . encodeUtf8 <$> ((message .: "voice") >>= ( .: "file_id"))
                     , AnimationMsg . encodeUtf8 <$> ((message .: "animation") >>= ( .: "file_id"))
                     , FileMsg . encodeUtf8 <$> ((message .: "document") >>= ( .: "file_id"))
                     , StickerMsg . encodeUtf8 <$> ((message .: "sticker") >>= ( .: "file_id"))
                     , photoPars (Object message)
                     , return UnsupportedMsg ]   
    return Update{..}

photoPars :: Pars Content
photoPars = withObject "Photo with Bot.Impl.TG.photoPars" $ \o -> do
    (x:_) <- V.toList <$> (o .: "photo")
    PhotoMsg . encodeUtf8 <$> (x .: "file_id")

callbackPars :: Pars Content
callbackPars = withObject "Command with Bot.Impl.TG.callbackPars" $ \o -> do
    str <- (o .: "data") :: Parser String
    case words str of
      ("/setRepeat":n:_) -> return $ CommandMsg $ Command'SetRepeat (read n)
      _                  -> fail "Wrong Callback"

commandPars :: Pars Content
commandPars = withObject "Command with Bot.Impl.TG.commandPars" $ \o -> do
    (x:_ )     <- (o .: "entities")
    entityType <- withObject "Entity type with Bot.Impl.TG.commandPars" ( .: "type") x :: Parser String
    guard (entityType == "bot_command")
    (txt:_) <- words <$> (o .: "text")
    case txt of
        "/help"       -> return $ CommandMsg Command'Help
        "/repeat"     -> return $ CommandMsg Command'Repeat
        _             -> fail $ "Unsupported Command"