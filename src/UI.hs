{-# LANGUAGE CPP #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module UI (app, St (..), toUIEventInfo, splitEventsToColumns, initSt) where

#if !(MIN_VERSION_base(4,11,0))
import Data.Monoid ((<>))
#endif

import Brick.AttrMap
  ( AttrMap,
    AttrName,
    attrMap,
    attrName,
  )
import Brick.BorderMap (Edges (..))
import Brick.Main qualified as BM
import Brick.Types qualified as BT
import Brick.Util qualified as BU
import Brick.Widgets.Border (borderWithLabel, hBorder, hBorderWithLabel, joinableBorder, vBorder)
import Brick.Widgets.Center (centerLayer)
import Brick.Widgets.Core
  ( Padding (..),
    emptyWidget,
    hBox,
    hLimit,
    joinBorders,
    padBottom,
    padLeft,
    padRight,
    padTop,
    str,
    txt,
    txtWrap,
    vBox,
    vLimit,
    viewport,
    visible,
    withAttr,
    withVScrollBars,
    (<+>),
    (<=>),
  )
import Brick.Widgets.Dialog
import Brick.Widgets.Edit
import Config (logicalTimeResolution, timelineTopBottomPadding)
import Control.Lens.At (ix)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Lazy
  ( MonadState (get, put),
    State,
    execState,
    modify,
  )
import Data.Function (on)
import Data.List (minimumBy, partition, sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (elems)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text.Lazy (toStrict)
import Data.Time
  ( Day,
    LocalTime (localDay),
    TimeZone,
    defaultTimeLocale,
    formatTime,
    getCurrentTime,
    getCurrentTimeZone,
    nominalDay,
    parseTimeM,
    timeToDaysAndTimeOfDay,
    utcToLocalTime,
  )
import DateTimeUtil
  ( getDateTimeDurationDescription,
    getDayDurationDescription,
    getLogicalDuration,
    happensOn,
  )
import EventInfo
  ( EventInfo (..),
    UIEventInfo (..),
    eventSortKey,
    prepareEventInfo,
  )
import Graphics.Vty qualified as V
import Lens.Micro ((&), (.~), (^.))
import Lens.Micro.Mtl ((%=))
import Lens.Micro.TH (makeLenses)
import ListCursor (ListCursor (..), mapToList, next, prev, tryApply)
import Text.ICalendar.Types qualified as C

data Name
  = EventVP
  | DateInput
  deriving (Ord, Eq, Show)

-- State of our app
data St = St
  { _stRawCalendars :: [C.VCalendar],
    _stTimeZone :: TimeZone,
    _stActiveDay :: Day,
    _stCursor :: Maybe (ListCursor UIEventInfo),
    _stDescOpen :: Bool,
    _stDateInput :: Editor String Name,
    _stDateInputOpen :: Bool,
    _stDateInputInvalid :: Bool
  }

makeLenses ''St

drawUi :: St -> [BT.Widget Name]
drawUi st = [drawModal st, drawEventViewport st]

drawModal :: St -> BT.Widget Name
drawModal st
  | st ^. stDateInputOpen = drawDateInput $ st
  | st ^. stDescOpen = drawDescriptionBox $ st ^. stCursor
  | otherwise = emptyWidget

drawDescriptionBox :: Maybe (ListCursor UIEventInfo) -> BT.Widget Name
drawDescriptionBox Nothing = emptyWidget
drawDescriptionBox (Just cursor) = renderDialog descriptionDialog (txtWrap $ toStrict description)
  where
    description = case eiDescription $ uiEventInfo $ lcSelected cursor of
      Just "" -> "No description"
      Just text -> text
      _ -> "No description"
    descriptionDialog = dialog (Just "Description") Nothing 50

drawDateInput :: St -> BT.Widget Name
drawDateInput st = centerLayer $ borderWithLabel (str "Go to (MM/DD/YYYY)") $ hLimit 20 content
  where
    editorWidget = renderEditor (str . concat) True $ st ^. stDateInput
    warning = if st ^. stDateInputInvalid then withAttr errorAttr $ str "Invalid date" else emptyWidget
    content = editorWidget <=> warning

drawEventViewport :: St -> BT.Widget Name
drawEventViewport st = drawHelper $ st ^. stCursor
  where
    label = str $ formatTime defaultTimeLocale "%m/%d/%0Y" (st ^. stActiveDay)
    banner = withAttr bannerAttr $ hBorderWithLabel label
    drawHelper :: Maybe (ListCursor UIEventInfo) -> BT.Widget Name
    drawHelper Nothing = banner <=> drawNormalEvents []
    drawHelper (Just cursor) =
      withVScrollBars BT.OnRight $ viewport EventVP BT.Vertical viewPortContent
      where
        events = mapToList updateUiSelected cursor
        updateUiSelected selected eventInfo = eventInfo {uiSelected = selected}
        (allDayEvents, normalEvents) = partition (eiAllDay . uiEventInfo) events
        viewPortContent =
          joinBorders $
            drawAllDayEvents allDayEvents
              <=> banner
              <=> drawNormalEvents normalEvents

getWithAttrIfSelected :: Bool -> (BT.Widget Name -> BT.Widget Name, BT.Widget Name -> BT.Widget Name)
getWithAttrIfSelected selected =
  if selected
    then (visible, withAttr selectedAttr)
    else (id, id)

joinableHBorder :: BT.Widget Name
joinableHBorder =
  joinableBorder (Edges False False False True)
    <+> hBorder
    <+> joinableBorder (Edges False False True False)

drawAllDayEvents :: [UIEventInfo] -> BT.Widget Name
drawAllDayEvents [] = emptyWidget
drawAllDayEvents events = padLeft (Pad 6) $ vBox (map drawEventBody events) <=> joinableHBorder
  where
    drawEventBody UIEventInfo {uiEventInfo = eventInfo, uiSelected = selected, uiDurationDescription = durationStr} =
      setVisible $ vLimit 3 $ joinableHBorder <=> (vBorder <+> setSelected (padRight Max $ row1 <=> row2) <+> vBorder)
      where
        EventInfo {eiTitle = title} = eventInfo
        row1 = txt $ toStrict $ fromMaybe "[No Title]" title
        row2 = str durationStr
        (setVisible, setSelected) = getWithAttrIfSelected selected

drawNormalEvents :: [UIEventInfo] -> BT.Widget Name
drawNormalEvents [] = padLeft (Pad 6) $ txt "Your timeline is empty today :)"
drawNormalEvents events = timelineWidget <+> hBox (zipWith withPadTop startTimes columnWidgets)
  where
    -- split events into non-overlapping columns
    columns = splitEventsToColumns events
    -- draw individual columns
    (columnWidgets, startTimes, endTimes) = unzip3 $ map drawEventColumn columns
    -- start and end time on the timeline
    startTime = max 0 $ minimum startTimes - timelineTopBottomPadding
    endTime = min (fromInteger $ round $ nominalDay / logicalTimeResolution) (maximum endTimes + timelineTopBottomPadding)
    -- add the right amount of top padding to each column to align with the timeline
    withPadTop amount = padTop (Pad (amount - startTime))
    timelineWidget = padRight (Pad 1) $ vBox $ map str timeOfDayStr
    timeOfDayStr = map (formatTime defaultTimeLocale "%R") timeSteps
    timeSteps =
      map
        (snd . timeToDaysAndTimeOfDay . (* logicalTimeResolution) . fromIntegral)
        [startTime, startTime + 1 .. endTime]

-- Split uiEvents into n non-overlapping columns
splitEventsToColumns :: [UIEventInfo] -> [NE.NonEmpty UIEventInfo]
splitEventsToColumns uiEvents = reverse $ map NE.reverse $ execState (splitHelper uiEvents) []
  where
    getColumnEndTime :: NE.NonEmpty UIEventInfo -> Int
    getColumnEndTime column = snd $ uiLogicalDuration $ NE.head column
    splitHelper :: [UIEventInfo] -> State [NE.NonEmpty UIEventInfo] ()
    splitHelper [] = return ()
    splitHelper (event : rest) = do
      -- a list of event existing columns
      columns <- get
      case columns of
        -- if we have no column, just add one
        [] -> do
          put [NE.fromList [event]]
          splitHelper rest
        -- if we have existing columns, check to see if they fit the current event
        _ ->
          do
            let startTime = fst $ uiLogicalDuration event
                pairs :: [(Int, NE.NonEmpty UIEventInfo)]
                pairs = zip [0 ..] columns
                -- find the column with earliest ending time
                (bestI, bestColumn) = minimumBy (compare `on` \(i, c) -> (getColumnEndTime c, i)) pairs
                earliestEndTime = getColumnEndTime bestColumn
            if earliestEndTime > startTime
              then -- if it doesn't fit, create a new column
              do
                put $ NE.fromList [event] : columns
                splitHelper rest
              else -- else just append to that column
              do
                put $ columns & ix bestI .~ event NE.<| bestColumn
                splitHelper rest

-- return (column of events, start time of the first event, end time of last event)
drawEventColumn :: NE.NonEmpty UIEventInfo -> (BT.Widget Name, Int, Int)
drawEventColumn uiEvents =
  ( vBox $ NE.toList $ NE.zipWith drawEventBody timeBetweenEvents uiEvents,
    fst $ uiLogicalDuration $ NE.head uiEvents,
    snd $ uiLogicalDuration $ NE.last uiEvents
  )
  where
    -- Time after each event before the next one starts
    -- Set it to 1 for the last event to make sure the last border is drawn
    timeBetweenEvents :: NE.NonEmpty Int
    timeBetweenEvents =
      NE.prependList
        (zipWith getTimeBetween (NE.toList uiEvents) (NE.tail uiEvents))
        (1 NE.:| [])

    getTimeBetween :: UIEventInfo -> UIEventInfo -> Int
    getTimeBetween lhs rhs
      | endLhs > startRhs = error "Events in a column should not overlap"
      | otherwise = startRhs - endLhs
      where
        (_, endLhs) = uiLogicalDuration lhs
        (startRhs, _) = uiLogicalDuration rhs

    drawEventBody :: Int -> UIEventInfo -> BT.Widget Name
    drawEventBody
      spaceAfter
      UIEventInfo
        { uiEventInfo = eventInfo,
          uiSelected = selected,
          uiDurationDescription = durationStr,
          uiLogicalDuration = (start, end)
        } =
        withPaddingAfter $ -- add padding after this cell if necessary
          setVisible $ -- make cell visible when selected
            joinableHBorder
              -- highlight cell content when selected
              <=> setSelected (vLimit contentHeight $ vBorder <+> padRight Max (row1 <=> row2) <+> vBorder)
              <=> bottomBorder
        where
          EventInfo {eiTitle = title} = eventInfo
          row1 = txt $ toStrict $ fromMaybe "[No Title]" title
          row2 = str durationStr
          contentHeight = end - start - 1
          -- the next cel may share the current cell's bottom border
          (bottomBorder, withPaddingAfter) = case spaceAfter of
            0 -> (emptyWidget, id)
            1 -> (joinableHBorder, id)
            _ -> (joinableHBorder, padBottom (Pad $ spaceAfter - 1))
          (setVisible, setSelected) = getWithAttrIfSelected selected

-- Creates a new ListCursor UIEventInfo by selecting all events that
-- overlaps with activateDay and setting the first event as the selected
-- event. If there's no event on activateDay, returns Nothing.
buildListCursor :: Day -> TimeZone -> [C.VEvent] -> Maybe (ListCursor UIEventInfo)
buildListCursor activeDay timeZone rawEvents = case uiEvents of
  (first : rest) -> Just (ListCursor first [] rest)
  _ -> Nothing
  where
    -- filter out all events that happen on activeDay
    events = filter (happensOn activeDay . eiDuration) $ mapMaybe (`prepareEventInfo` timeZone) rawEvents
    -- sort by (is all day, start date time, uid) ascending
    sortedEventInfo = sortOn eventSortKey events
    -- add information needed for drawing events
    uiEvents = map (toUIEventInfo activeDay) sortedEventInfo

toUIEventInfo :: Day -> EventInfo -> UIEventInfo
toUIEventInfo activeDay ei =
  let duration = eiDuration ei
      allDay = eiAllDay ei
      durationDescription =
        if allDay
          then getDayDurationDescription activeDay duration
          else getDateTimeDurationDescription activeDay duration
   in UIEventInfo
        { uiEventInfo = ei,
          uiLogicalDuration = getLogicalDuration activeDay duration,
          uiSelected = False, -- set it to false For now
          uiDurationDescription = durationDescription
        }

-- Initialize the cursor
appStartEvent :: BT.EventM Name St ()
appStartEvent = do
  st <- get
  let activeDay = st ^. stActiveDay
      timeZone = st ^. stTimeZone
      rawEvents = concatMap (elems . C.vcEvents) (st ^. stRawCalendars)
  put (st & stCursor .~ buildListCursor activeDay timeZone rawEvents)

-- Update stActiveDay with f and update the cursor accordingly
updateActiveDay :: (Day -> Day) -> St -> St
updateActiveDay f st =
  st
    & stCursor .~ cursor
    & stActiveDay .~ activeDay
    & stDescOpen .~ False
    & stDateInputOpen .~ False
    & stDateInput .~ newEditor
    & stDateInputInvalid .~ False
  where
    activeDay = f $ st ^. stActiveDay
    timeZone = st ^. stTimeZone
    rawEvents = concatMap (elems . C.vcEvents) (st ^. stRawCalendars)
    cursor = buildListCursor activeDay timeZone rawEvents

updateTimeZone :: TimeZone -> St -> St
updateTimeZone timeZone st = st & stTimeZone .~ timeZone

appEvent :: BT.BrickEvent Name e -> BT.EventM Name St ()
appEvent event = do
  st <- get
  if st ^. stDateInputOpen
    then handleDateInputEvent event
    else handleNormalEvents event

handleNormalEvents :: BT.BrickEvent Name e -> BT.EventM Name St ()
handleNormalEvents (BT.VtyEvent (V.EvKey V.KEsc [])) = BM.halt
handleNormalEvents (BT.VtyEvent (V.EvKey V.KDown [])) =
  stCursor %= tryApply next
handleNormalEvents (BT.VtyEvent (V.EvKey V.KUp [])) =
  stCursor %= tryApply prev
handleNormalEvents (BT.VtyEvent (V.EvKey V.KRight [])) = do
  modify $ updateActiveDay succ
handleNormalEvents (BT.VtyEvent (V.EvKey V.KLeft [])) =
  modify $ updateActiveDay pred
handleNormalEvents (BT.VtyEvent (V.EvKey V.KEnter [])) =
  stDescOpen %= not
handleNormalEvents (BT.VtyEvent (V.EvKey (V.KChar 'g') [])) =
  stDateInputOpen %= not
handleNormalEvents (BT.VtyEvent (V.EvKey (V.KChar 't') [])) = do
  utcTime <- liftIO getCurrentTime
  timeZone <- liftIO getCurrentTimeZone
  let today = localDay $ utcToLocalTime timeZone utcTime
  modify $ updateTimeZone timeZone . updateActiveDay (const today)
handleNormalEvents _ = return ()

handleDateInputEvent :: BT.BrickEvent Name e -> BT.EventM Name St ()
handleDateInputEvent (BT.VtyEvent (V.EvKey V.KEsc [])) =
  stDateInputOpen %= not
handleDateInputEvent (BT.VtyEvent (V.EvKey V.KEnter [])) = do
  st <- get
  let dateString = concat $ getEditContents $ st ^. stDateInput
      parseResult :: Maybe Day
      parseResult = parseTimeM True defaultTimeLocale "%m/%d/%0Y" dateString
  case parseResult of
    Nothing -> stDateInputInvalid %= const True
    Just day -> modify $ updateActiveDay $ const day
handleDateInputEvent event = BT.zoom stDateInput $ handleEditorEvent event

selectedAttr :: AttrName
selectedAttr = attrName "selected"

bannerAttr :: AttrName
bannerAttr = attrName "banner"

errorAttr :: AttrName
errorAttr = attrName "error"

theMap :: AttrMap
theMap =
  attrMap
    V.defAttr
    [ (selectedAttr, V.black `BU.on` V.yellow),
      (bannerAttr, V.black `BU.on` V.white),
      (errorAttr, V.white `BU.on` V.red),
      (editAttr, V.white `BU.on` V.blue)
    ]

newEditor :: Editor String Name
newEditor = editor DateInput (Just 1) ""

initSt :: [C.VCalendar] -> TimeZone -> Day -> St
initSt calendars timeZone activeDay =
  St
    { _stRawCalendars = calendars,
      _stTimeZone = timeZone,
      _stActiveDay = activeDay,
      _stCursor = Nothing,
      _stDescOpen = False,
      _stDateInput = newEditor,
      _stDateInputOpen = False,
      _stDateInputInvalid = False
    }

app :: BM.App St e Name
app =
  BM.App
    { BM.appDraw = drawUi,
      BM.appStartEvent = appStartEvent,
      BM.appHandleEvent = appEvent,
      BM.appAttrMap = const theMap,
      BM.appChooseCursor = BM.neverShowCursor
    }
