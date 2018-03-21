{-# LANGUAGE OverloadedLabels #-}
module StatusNotifier.Tray where

import           Control.Concurrent.MVar as MV
import           Control.Monad
import           Control.Monad.Trans
import           Control.Monad.Trans.Maybe (MaybeT(..))
import           Control.Monad.Trans.Reader
import           DBus.Client
import qualified DBus.Internal.Types as DBusTypes
import qualified Data.ByteString as BS
import           Data.ByteString.Unsafe
import           Data.Coerce
import           Data.Int
import qualified Data.Map.Strict as Map
import           Data.Maybe
import qualified Data.Text as T
import           Foreign.Ptr
import qualified GI.DbusmenuGtk3.Objects.Menu as DM
import qualified GI.GLib as GLib
import           GI.GLib.Structs.Bytes
import qualified GI.Gdk as Gdk
import           GI.Gdk.Enums
import           GI.Gdk.Objects.Screen
import           GI.GdkPixbuf.Callbacks
import           GI.GdkPixbuf.Enums
import           GI.GdkPixbuf.Objects.Pixbuf
import           GI.GdkPixbuf.Structs.Pixdata
import qualified GI.Gtk as Gtk
import           GI.Gtk.Flags
import qualified GI.Gtk.Objects.Box as Gtk
import qualified GI.Gtk.Objects.HBox as Gtk
import           GI.Gtk.Objects.IconTheme
import           StatusNotifier.Host.Service
import           System.Log.Logger
import           Text.Printf

themeLoadFlags = [IconLookupFlagsGenericFallback, IconLookupFlagsUseBuiltin]

getThemeWithDefaultFallbacks :: String -> IO IconTheme
getThemeWithDefaultFallbacks themePath = do
  themeForIcon <- iconThemeNew
  defaultTheme <- iconThemeGetDefault

  runMaybeT $ do
    screen <- MaybeT screenGetDefault
    lift $ iconThemeSetScreen themeForIcon screen

  filePaths <- iconThemeGetSearchPath defaultTheme
  iconThemeAppendSearchPath themeForIcon themePath
  mapM_ (iconThemeAppendSearchPath themeForIcon) filePaths

  return themeForIcon

getIconPixbufByName :: IsIconTheme it =>  Int32 -> T.Text -> it -> IO (Maybe Pixbuf)
getIconPixbufByName size name themeForIcon = do
  let panelName = T.pack $ printf "%s-panel" name
  hasPanelIcon <- iconThemeHasIcon themeForIcon panelName
  let targetName = if hasPanelIcon then panelName else name
  iconThemeLoadIcon themeForIcon targetName size themeLoadFlags

getIconPixbufFromByteString :: Int32 -> Int32 -> BS.ByteString -> IO Pixbuf
getIconPixbufFromByteString width height byteString = do
  bytes <- bytesNew $ Just byteString
  let bytesPerPixel = 4
      rowStride = width * bytesPerPixel
      sampleBits = 8
  pixbufNewFromBytes bytes ColorspaceRgb True sampleBits width height rowStride

data ItemContext = ItemContext
  { contextInfo :: ItemInfo
  , contextMenu :: DM.Menu
  , contextImage :: Gtk.Image
  , contextButton :: Gtk.Button
  }

data TrayParams = TrayParams
  { trayLogger :: Logger }

buildTrayWithHost :: IO Gtk.Box
buildTrayWithHost = do
  client <- connectSession
  logger <- getRootLogger
  (tray, updateHandler) <- buildTray TrayParams { trayLogger = logger }
  _ <- join $ build defaultParams
       { uniqueIdentifier = "taffybar"
       , handleUpdate = updateHandler
       , dbusClient = Just client
       }
  return tray

buildTray :: TrayParams -> IO (Gtk.Box, UpdateType -> ItemInfo -> IO ())
buildTray TrayParams { trayLogger = logger } = do
  trayBox <- Gtk.boxNew Gtk.OrientationHorizontal 0
  widgetMap <- MV.newMVar Map.empty

  let getContext name = Map.lookup name <$> MV.readMVar widgetMap

      updateHandler ItemAdded
                    info@ItemInfo { menuPath = pathForMenu
                                  , itemServiceName = serviceName
                                  , itemServicePath = servicePath
                                  } =
        do
          let serviceNameStr = coerce serviceName
              servicePathStr = coerce servicePath :: String
              serviceMenuPathStr = coerce pathForMenu
              logText = printf "Adding widget for %s - %s."
                        serviceNameStr servicePathStr

          logL logger INFO logText
          pixBuf <- getPixBufFromInfo info
          image <- Gtk.imageNewFromPixbuf (Just pixBuf)
          button <- Gtk.buttonNew
          menu <- DM.menuNew (T.pack serviceNameStr) (T.pack serviceMenuPathStr)

          Gtk.containerAdd button image
          Gtk.widgetShowAll button
          Gtk.boxPackStart trayBox button True True 0

          let context =
                ItemContext { contextInfo = info
                            , contextMenu = menu
                            , contextImage = image
                            , contextButton = button
                            }
              popupItemMenu =
                Gtk.menuPopupAtWidget menu button
                   GravitySouthWest GravityNorthWest Nothing

          Gtk.onButtonClicked button popupItemMenu

          MV.modifyMVar_ widgetMap $ return . (Map.insert serviceName context)

      updateHandler ItemRemoved ItemInfo { itemServiceName = name }
        = getContext name >>= removeWidget
        where removeWidget Nothing =
                logL logger INFO "Attempt to remove widget with unrecognized service name."
              removeWidget (Just (ItemContext { contextButton = widgetToRemove })) =
                do
                  Gtk.containerRemove trayBox widgetToRemove
                  MV.modifyMVar_ widgetMap $ return . (Map.delete name)

      updateHandler _ _ = return ()

      getPixBufFromInfo ItemInfo { iconName = name
                                 , iconThemePath = mpath
                                 , iconPixmaps = pixmaps
                                 } = do
        themeForIcon <- fromMaybe iconThemeGetDefault $ getThemeWithDefaultFallbacks <$> mpath
        mpixBuf <- (getIconPixbufByName 30 (T.pack name) themeForIcon)
        let getFromPixmaps (w, h, p) = getIconPixbufFromByteString w h p
        -- XXX: Fix me: don't use head here
        maybe (getFromPixmaps (head pixmaps)) return mpixBuf

      uiUpdateHandler updateType info =
        void $ Gdk.threadsAddIdle GLib.PRIORITY_DEFAULT $
             updateHandler updateType info >> return False

  return (trayBox, uiUpdateHandler)

