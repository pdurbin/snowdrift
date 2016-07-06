{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | Subsite for email-and-passphrase authentication.
module AuthSite (module AuthSiteTypes, module AuthSite) where

import Prelude

import Control.Error
import Control.Lens
import Control.Monad
import Crypto.Nonce (Generator, nonce128urlT)
import Crypto.PasswordStore
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text.Encoding
import Data.Time
import Data.Typeable
import Database.Persist.Sql
import Yesod
import qualified Crypto.Nonce as Nonce

-- Used to create a single, applicationd-wide nonce token. I'm doing this
-- out of expediency; Yesod.Auth uses it and nobody seems to care. But I
-- don't like it.
-- https://github.com/yesodweb/yesod/issues/1245
import System.IO.Unsafe (unsafePerformIO)

import AuthSiteTypes

-- Need this until we switch back to using messages instead of
-- Yesod-specific "alerts".
import Alerts

-- Still need this until we take the time to put ''type AuthUser'' into the
-- AuthMaster class
import Model
type AuthUser = Entity User

-- | Any site that uses this subsite needs to instantiate this class.
class AuthMaster y where

    -- | Where to go after logout and login
    postLoginRoute :: y -> Route y
    postLogoutRoute :: y -> Route y

    -- | What to show on the login page. This page should have a form that posts
    -- 'Credentials' to 'LoginR'. See 'AuthHarness' in the tests for a
    -- simplistic example.
    loginHandler :: HandlerT y IO TypedContent

    -- | What to show on the create-account page. This page should post
    -- 'Credentials' to 'CreateAccountR'.
    createAccountHandler :: HandlerT y IO TypedContent

-- ** Internal types. Sequestered up here to appease the TH gods.

newtype AuthEmail = AuthEmail { fromAuth :: Text } deriving Show

newtype ClearPassphrase = ClearPassphrase { fromClear :: Text } deriving Show

newtype PassphraseDigest = PassphraseDigest ByteString deriving Show

data Credentials = Credentials
        { loginAuth :: AuthEmail
        , loginPass :: ClearPassphrase
        } deriving (Show)

data VerifiedUser = VerifiedUser
        { verifiedEmail :: Text
        , verifiedDigest :: ByteString
        }

data Verification = Verification
        { verifyEmail :: AuthEmail
        , verifyToken :: Text
        }

-- | Used with Yesod caching feature
newtype CachedAuth a = CachedAuth { unCachedAuth :: Maybe a } deriving Typeable

-- ** Invoke Yesod TH to make the subsite.

instance (Yesod master
         ,YesodPersist master
         ,YesodPersistBackend master ~ SqlBackend
         ,RenderMessage master FormMessage
         ,AuthMaster master)
        => YesodSubDispatch AuthSite (HandlerT master IO) where
    yesodSubDispatch = $(mkYesodSubDispatch resourcesAuthSite)

-- ** Duplicating Yesod.Auth API for a wee while.

maybeAuth :: (YesodPersist m
             ,YesodPersistBackend m ~ SqlBackend)
          => HandlerT m IO (Maybe AuthUser)
maybeAuth = runMaybeT $ do
    k <- MaybeT $ lookupSession authSessionKey
    uid <- MaybeT $ pure (fromPathPiece k)
    u <- MaybeT $ fmap unCachedAuth (cached (runDB $ fmap CachedAuth (get uid)))
    pure (Entity uid u)

requireAuth :: (Yesod m
               ,YesodPersist m
               ,YesodPersistBackend m ~ SqlBackend)
            => HandlerT m IO AuthUser
requireAuth = maybe noAuth pure =<< maybeAuth
  where
    noAuth = do
        setUltDestCurrent
        maybe notAuthenticated redirect . authRoute =<< getYesod

-- | A decent default form for 'Credentials', to be considered part of the
-- external API.
credentialsForm :: (RenderMessage (HandlerSite m) FormMessage, MonadHandler m)
          => AForm m Credentials
credentialsForm = Credentials
    <$> (AuthEmail <$> areq textField "Email"{fsAttrs=emailAttrs}  Nothing)
    <*> (ClearPassphrase <$> areq passwordField "Passphrase" Nothing)
  where
    emailAttrs = [("autofocus",""), ("autocomplete","email")]

-- ** Functions and operations for doing auth. To be considered internal.

authSessionKey :: Text
authSessionKey = "_AUTHID"

-- Per the docs, this number should increase by 1 every two years, starting
-- at 17 in 2014. Thus, 17 + (now^.year - 2014) / 2. We could even TH that
-- bizniss.
--
-- Ok, I TH'd it. Will I regret it? Yes. Leaving it commented for
-- now.
pbkdf1Strength :: Int
pbkdf1Strength = 18
-- pbkdf1Strength = 17 + (yr - 2014) `div` 2
--   where yr = $(litE =<< runIO (fmap ( IntegerL
--                                     . (\(a,_,_) -> a)
--                                     . toGregorian
--                                     . utctDay)
--                                     getCurrentTime))

-- | Yesod.Auth uses this, and it's apparently ok.
-- https://github.com/yesodweb/yesod/issues/1245
tokenGenerator :: Generator
tokenGenerator = unsafePerformIO Nonce.new
{-# NOINLINE tokenGenerator #-}

-- | Compare some Credentials to what's stored in the database.
checkCredentials :: MonadIO m => Credentials -> SqlPersistT m (Maybe AuthUser)
checkCredentials Credentials{..} = do
    mu <- getBy (UniqueUsr (fromAuth loginAuth))
    pure $ verify =<< mu
  where
    verify x@(Entity uid u) =
        if verifyPassword (encodeUtf8 (fromClear loginPass)) (u^.userDigest)
            then Just x
            else Nothing

-- | Store a provisional user for later verification. Returns the token to
-- use for verification.
storeProvisionalUser :: MonadIO m => Credentials -> SqlPersistT m Verification
storeProvisionalUser creds = do
    tok <- liftIO (genVerificationToken creds)
    insert_ =<< liftIO (provisional creds tok)
    pure tok

-- | Create a provisional user
provisional :: Credentials -> Verification -> IO ProvisionalUser
provisional Credentials{..} Verification{..} =
    ProvisionalUser <$> email <*> passDigest <*> tokDigest <*> curtime
  where
    email = pure (fromAuth loginAuth)
    passDigest = makePass (fromClear loginPass)
    tokDigest = makePass verifyToken
    curtime = getCurrentTime
    makePass t = makePassword (encodeUtf8 t) pbkdf1Strength

genVerificationToken :: Credentials -> IO Verification
genVerificationToken Credentials{..} =
    Verification loginAuth <$> nonce128urlT tokenGenerator

-- | This privileged function must be used with care.
privilegedCreateUser :: MonadIO m => VerifiedUser -> SqlPersistT m ()
privilegedCreateUser VerifiedUser{..} =
    insert_ (User verifiedEmail verifiedDigest)

-- | This privileged function must be used with care. It modifies the
-- user's session; it's the difference between being logged in and not!
priviligedLogin :: Yesod master => AuthUser -> HandlerT master IO ()
priviligedLogin = setSession authSessionKey . toPathPiece . entityKey

getLoginR :: (Yesod m, RenderMessage m FormMessage, AuthMaster m)
          => HandlerT AuthSite (HandlerT m IO) TypedContent
getLoginR = lift $ loginHandler

postLoginR :: (Yesod master
              ,AuthMaster master
              ,YesodPersist master
              ,YesodPersistBackend master ~ SqlBackend
              ,RenderMessage master FormMessage)
           => HandlerT AuthSite (HandlerT master IO) Html
postLoginR = do
    ((res', _), _) <- lift $ runFormPost (renderDivs credentialsForm)
    p <- getRouteToParent
    formResult (lift . (runAuthResult p <=< (runDB . checkCredentials)))
               loginAgain
               res'
  where
    runAuthResult parent = maybe
        (do
            alertDanger [shamlet|Bad credentials:  <a href="https://tree.taiga.io/project/snowdrift/us/392">See Taiga #392</a>.|]
            redirect (parent LoginR))
        (\u -> do
            priviligedLogin u
            alertInfo "Welcome"
            redirect =<< (postLoginRoute <$> getYesod))
    loginAgain msgs =
        lift $ defaultLayout [whamlet|
            <p>Login form failures are not handled yet.
            <p>TBD: <a href="https://tree.taiga.io/project/snowdrift/us/392">See Taiga #392</a>.
            <p>Errors: #{show msgs}
            |]

    formResult success failure = \case
        FormSuccess x -> success x
        FormFailure msgs -> failure msgs
        FormMissing -> failure ["No login data"]

-- ** Logout page

postLogoutR :: (Yesod master
               ,AuthMaster master)
            => HandlerT AuthSite (HandlerT master IO) Html
postLogoutR = do
    lift $ deleteSession authSessionKey
    lift $ redirect =<< (postLogoutRoute <$> getYesod)

-- ** CreateAccount page

getCreateAccountR :: (Yesod m, RenderMessage m FormMessage, AuthMaster m)
                  => HandlerT AuthSite (HandlerT m IO) TypedContent
getCreateAccountR = lift $ createAccountHandler

postCreateAccountR :: HandlerT AuthSite (HandlerT master IO) Html
postCreateAccountR = undefined
