{-# LANGUAGE CPP #-}

-- | TestHooks puts all dicey test-environment overrides in one place.
module TestHooks (middleware, authPlugins, sendVerifyEmail) where

import Import.NoFoundation hiding (authPlugins)

#if DEVELOPMENT
import Yesod.Auth.Dummy (authDummy)
#endif
import Yesod.Auth.Email (YesodAuthEmail, authEmail)

-- | Don't use CSRF in testing.
middleware :: (Yesod site, ToTypedContent res)
           => HandlerT site IO res -> HandlerT site IO res
middleware = addCsrf . defaultYesodMiddleware
  where
#if DEVELOPMENT
    addCsrf = id
#else
    addCsrf = defaultCsrfMiddleware
#endif

-- | Enable dummy auth (Yesod.Auth.Dummy) in testing.
authPlugins :: (YesodAuth master, YesodAuthEmail master) => [AuthPlugin master]
authPlugins = addDummy [authEmail]
  where
#if DEVELOPMENT
    addDummy = (authDummy :)
#else
    addDummy = id
#endif

-- | Don't actually send email in testing OR development.
-- FIXME: Do send email in production, though :D
sendVerifyEmail :: MonadLogger m => Text -> t -> Text -> m ()
sendVerifyEmail e _k u = $logDebug ("Hit up " <> u <> " to authorize " <> e <> " .")