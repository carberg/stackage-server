module Foundation where

import           ClassyPrelude.Yesod
import           Data.Slug (safeMakeSlug, HasGenIO (getGenIO), randomSlug, Slug)
import           Data.WebsiteContent
import qualified Database.Persist
import           Database.Persist.Sql (PersistentSqlException (Couldn'tGetSQLConnection))
import           Model
import qualified Settings
import           Settings (widgetFile, Extra (..), GoogleAuth (..))
import           Settings.Development (development)
import           Settings.StaticFiles
import qualified System.Random.MWC as MWC
import           Text.Blaze
import           Text.Hamlet (hamletFile)
import           Types
import           Yesod.Auth
import           Yesod.Auth.BrowserId
import           Yesod.Auth.GoogleEmail2 (authGoogleEmail)
import           Yesod.Core.Types (Logger)
import           Yesod.Default.Config
import           Yesod.GitRepo
import Stackage.Database

-- | The site argument for your application. This can be a good place to
-- keep settings and values requiring initialization before your application
-- starts running, such as database connections. Every handler will have
-- access to the data present here.
data App = App
    { settings :: AppConfig DefaultEnv Extra
    , getStatic :: Static -- ^ Settings for static file serving.
    , connPool :: Database.Persist.PersistConfigPool Settings.PersistConf -- ^ Database connection pool.
    , httpManager :: Manager
    , persistConfig :: Settings.PersistConf
    , appLogger :: Logger
    , genIO :: MWC.GenIO
    , websiteContent :: GitRepo WebsiteContent
    , stackageDatabase :: IO StackageDatabase
    }

instance HasGenIO App where
    getGenIO = genIO

instance HasHttpManager App where
    getHttpManager = httpManager

instance HasHackageRoot App where
    getHackageRoot = hackageRoot . appExtra . settings

-- This is where we define all of the routes in our application. For a full
-- explanation of the syntax, please see:
-- http://www.yesodweb.com/book/routing-and-handlers
--
-- Note that this is really half the story; in Application.hs, mkYesodDispatch
-- generates the rest of the code. Please see the linked documentation for an
-- explanation for this split.
mkYesodData "App" $(parseRoutesFile "config/routes")

type Form x = Html -> MForm (HandlerT App IO) (FormResult x, Widget)

defaultLayoutNoContainer :: Widget -> Handler Html
defaultLayoutNoContainer = defaultLayoutWithContainer False

defaultLayoutWithContainer :: Bool -> Widget -> Handler Html
defaultLayoutWithContainer insideContainer widget = do
    mmsg <- getMessage
    muser <- catch maybeAuth $ \e -> case e of
        Couldn'tGetSQLConnection -> return Nothing
        _ -> throwM e

    -- We break up the default layout into two components:
    -- default-layout is the contents of the body tag, and
    -- default-layout-wrapper is the entire page. Since the final
    -- value passed to hamletToRepHtml cannot be a widget, this allows
    -- you to use normal widget features in default-layout.

    cur <- getCurrentRoute
    pc <- widgetToPageContent $ do
        $(combineStylesheets 'StaticR
            [ css_normalize_css
            , css_bootstrap_css
            , css_bootstrap_responsive_css
            ])
        $((combineScripts 'StaticR
                          [ js_jquery_js
                          , js_bootstrap_js
                          ]))
        $(widgetFile "default-layout")

    mcurr <- getCurrentRoute
    let notHome = mcurr /= Just HomeR

    withUrlRenderer $(hamletFile "templates/default-layout-wrapper.hamlet")

-- Please see the documentation for the Yesod typeclass. There are a number
-- of settings which can be configured by overriding methods here.
instance Yesod App where
    approot = ApprootMaster $ appRoot . settings

    -- Store session data on the client in encrypted cookies,
    -- default session idle timeout is 120 minutes
    makeSessionBackend _ = fmap Just $ defaultClientSessionBackend
        (120 * 60) -- 120 minutes
        "config/client_session_key.aes"

    defaultLayout = defaultLayoutWithContainer True

    -- Ideally we would just have an approot that always includes https, and
    -- redirect users from non-SSL to SSL connections. However, cabal-install
    -- is broken, and does not support TLS. Therefore, we *don't* force the
    -- redirect.
    --
    -- Nonetheless, we want to keep generated links as https:// links. The
    -- problem is that sometimes CORS kicks in and breaks a static resource
    -- when loading from a non-secure page. So we have this ugly hack: whenever
    -- the destination is a static file, don't include the scheme or hostname.
    urlRenderOverride y route@StaticR{} =
        Just $ uncurry (joinPath y "") $ renderRoute route
    urlRenderOverride _ _ = Nothing

    -- The page to be redirected to when authentication is required.
    authRoute _ = Just $ AuthR LoginR

    {- Temporarily disable to allow for horizontal scaling
    -- This function creates static content files in the static folder
    -- and names them based on a hash of their content. This allows
    -- expiration dates to be set far in the future without worry of
    -- users receiving stale content.
    addStaticContent =
        addStaticContentExternal minifym genFileName Settings.staticDir (StaticR . flip StaticRoute [])
      where
        -- Generate a unique filename based on the content itself
        genFileName lbs
            | development = "autogen-" ++ base64md5 lbs
            | otherwise   = base64md5 lbs
    -}

    -- Place Javascript at bottom of the body tag so the rest of the page loads first
    jsLoader _ = BottomOfBody

    -- What messages should be logged. The following includes all messages when
    -- in development, and warnings and errors in production.
    shouldLog _ "CLEANUP" _ = False
    shouldLog _ source level =
        development || level == LevelWarn || level == LevelError || source == "CLEANUP"

    makeLogger = return . appLogger

    maximumContentLength _ _ = Just 2000000

instance ToMarkup (Route App) where
    toMarkup c =
        case c of
          AllSnapshotsR{} -> "Snapshots"
          AuthR (LoginR{}) -> "Login"
          _ -> ""

-- How to run database actions.
instance YesodPersist App where
    type YesodPersistBackend App = SqlBackend
    runDB = defaultRunDB persistConfig connPool
instance YesodPersistRunner App where
    getDBRunner = defaultGetDBRunner connPool

instance YesodAuth App where
    type AuthId App = UserId

    -- Where to send a user after successful login
    loginDest _ = HomeR
    -- Where to send a user after logout
    logoutDest _ = HomeR

    redirectToReferer _ = True

    getAuthId creds = do
        muid <- maybeAuthId
        join $ runDB $ case muid of
            Nothing -> do
                x <- getBy $ UniqueEmail $ credsIdent creds
                case x of
                    Just (Entity _ email) -> return $ return $ Just $ emailUser email
                    Nothing -> do
                        handle' <- getHandle (0 :: Int)
                        token <- getToken
                        userid <- insert User
                            { userHandle = handle'
                            , userDisplay = credsIdent creds
                            , userToken = token
                            }
                        insert_ Email
                            { emailEmail = credsIdent creds
                            , emailUser = userid
                            }
                        return $ return $ Just userid
            Just uid -> do
                memail <- getBy $ UniqueEmail $ credsIdent creds
                case memail of
                    Nothing -> do
                        insert_ Email
                            { emailEmail = credsIdent creds
                            , emailUser = uid
                            }
                        return $ do
                            setMessage $ toHtml $ concat
                                [ "Email address "
                                , credsIdent creds
                                , " added to your account."
                                ]
                            redirect ProfileR
                    Just (Entity _ email)
                        | emailUser email == uid -> return $ do
                            setMessage $ toHtml $ concat
                                [ "The email address "
                                , credsIdent creds
                                , " is already part of your account"
                                ]
                            redirect ProfileR
                        | otherwise -> invalidArgs $ return $ concat
                            [ "The email address "
                            , credsIdent creds
                            , " is already associated with a different account."
                            ]
      where
        handleBase = takeWhile (/= '@') (credsIdent creds)
        getHandle cnt | cnt > 50 = error "Could not get a unique slug"
        getHandle cnt = do
            slug <- lift $ safeMakeSlug handleBase (cnt > 0)
            muser <- getBy $ UniqueHandle slug
            case muser of
                Nothing -> return slug
                Just _  -> getHandle (cnt + 1)

    -- You can add other plugins like BrowserID, email or OAuth here
    authPlugins app =
        authBrowserId def : google
      where
        google =
            case googleAuth $ appExtra $ settings app of
                Nothing -> []
                Just GoogleAuth {..} -> [authGoogleEmail gaClientId gaClientSecret]

    authHttpManager = httpManager
instance YesodAuthPersist App

getToken :: YesodDB App Slug
getToken =
    go (0 :: Int)
  where
    go cnt | cnt > 50 = error "Could not get a unique token"
    go cnt = do
        slug <- lift $ randomSlug 25
        muser <- getBy $ UniqueToken slug
        case muser of
            Nothing -> return slug
            Just _  -> go (cnt + 1)

-- This instance is required to use forms. You can modify renderMessage to
-- achieve customized and internationalized form validation messages.
instance RenderMessage App FormMessage where
    renderMessage _ _ = defaultFormMessage

-- | Get the 'Extra' value, used to hold data from the settings.yml file.
getExtra :: Handler Extra
getExtra = fmap (appExtra . settings) getYesod

-- Note: previous versions of the scaffolding included a deliver function to
-- send emails. Unfortunately, there are too many different options for us to
-- give a reasonable default. Instead, the information is available on the
-- wiki:
--
-- https://github.com/yesodweb/yesod/wiki/Sending-email

instance GetStackageDatabase Handler where
    getStackageDatabase = getYesod >>= liftIO . stackageDatabase
instance GetStackageDatabase (WidgetT App IO) where
    getStackageDatabase = getYesod >>= liftIO . stackageDatabase
