{-# LANGUAGE CPP #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ScopedTypeVariables #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.Actions.CycleRecentWS
-- Copyright   :  (c) Michal Janeczek <janeczek@gmail.com>
-- License     :  BSD3-style (see LICENSE)
--
-- Maintainer  :  Michal Janeczek <janeczek@gmail.com>
-- Stability   :  unstable
-- Portability :  unportable
--
-- Provides bindings to cycle through most recently used workspaces
-- with repeated presses of a single key (as long as modifier key is
-- held down). This is similar to how many window managers handle
-- window switching.
--
-----------------------------------------------------------------------------

module XMonad.Actions.CycleRecentWS (
                                -- * Usage
                                -- $usage
                                cycleRecentWS,
                                cycleRecentNonEmptyWS,
                                cycleWindowSets,
                                toggleRecentWS,
                                toggleRecentNonEmptyWS,
                                toggleWindowSets,
                                recentWS,

#ifdef TESTING
                                unView,
#endif
) where

import XMonad hiding (workspaces)
import XMonad.StackSet hiding (filter)

import Control.Arrow ((&&&))
import Data.Function (on)

-- $usage
-- You can use this module with the following in your @~\/.xmonad\/xmonad.hs@ file:
--
-- > import XMonad.Actions.CycleRecentWS
-- >
-- >   , ((modm, xK_Tab), cycleRecentWS [xK_Alt_L] xK_Tab xK_grave)
--
-- For detailed instructions on editing your key bindings, see
-- "XMonad.Doc.Extending#Editing_key_bindings".

-- | Cycle through most recent workspaces with repeated presses of a key, while
--   a modifier key is held down. The recency of workspaces previewed while browsing
--   to the target workspace is not affected. That way a stack of most recently used
--   workspaces is maintained, similarly to how many window managers handle window
--   switching. For best effects use the same modkey+key combination as the one used
--   to invoke this action.
cycleRecentWS :: [KeySym] -- ^ A list of modifier keys used when invoking this action.
                          --   As soon as one of them is released, the final switch is made.
              -> KeySym   -- ^ Key used to switch to next (less recent) workspace.
              -> KeySym   -- ^ Key used to switch to previous (more recent) workspace.
                          --   If it's the same as the nextWorkspace key, it is effectively ignored.
              -> X ()
cycleRecentWS = cycleWindowSets $ recentWS (const True)


-- | Like 'cycleRecentWS', but restricted to non-empty workspaces.
cycleRecentNonEmptyWS :: [KeySym] -- ^ A list of modifier keys used when invoking this action.
                                  --   As soon as one of them is released, the final switch is made.
                      -> KeySym   -- ^ Key used to switch to next (less recent) workspace.
                      -> KeySym   -- ^ Key used to switch to previous (more recent) workspace.
                                  --   If it's the same as the nextWorkspace key, it is effectively ignored.
                      -> X ()
cycleRecentNonEmptyWS = cycleWindowSets $ recentWS (not . null . stack)


-- | Switch to the most recent workspace. The stack of most recently used workspaces
-- is updated, so repeated use toggles between a pair of workspaces.
toggleRecentWS :: X ()
toggleRecentWS = toggleWindowSets $ recentWS (const True)


-- | Like 'toggleRecentWS', but restricted to non-empty workspaces.
toggleRecentNonEmptyWS :: X ()
toggleRecentNonEmptyWS = toggleWindowSets $ recentWS (not . null . stack)


-- | Given a predicate @p@ and the current 'WindowSet' @w@, create a
-- list of workspaces to choose from. They are ordered by recency and
-- have to satisfy @p@.
recentWS :: (WindowSpace -> Bool) -- ^ A workspace predicate.
         -> WindowSet             -- ^ The current WindowSet
         -> [WorkspaceId]
recentWS p w = map tag
             $ filter p
             $ map workspace (visible w)
               ++ hidden w
               ++ [workspace (current w)]

-- | Cycle through a finite list of workspaces with repeated presses of a key, while
--   a modifier key is held down. For best effects use the same modkey+key combination
--   as the one used to invoke this action.
cycleWindowSets :: (WindowSet -> [WorkspaceId]) -- ^ A function used to create a list of workspaces to choose from
                -> [KeySym]                     -- ^ A list of modifier keys used when invoking this action.
                                                --   As soon as one of them is released, the final workspace is chosen and the action exits.
                -> KeySym                       -- ^ Key used to preview next workspace from the list of generated options
                -> KeySym                       -- ^ Key used to preview previous workspace from the list of generated options.
                                                --   If it's the same as nextOption key, it is effectively ignored.
                -> X ()
cycleWindowSets genOptions mods keyNext keyPrev = do
  (options, unView') <- gets $ (genOptions &&& unView) . windowset
  XConf {theRoot = root, display = d} <- ask
  let event = allocaXEvent $ \p -> do
                maskEvent d (keyPressMask .|. keyReleaseMask) p
                KeyEvent {ev_event_type = t, ev_keycode = c} <- getEvent p
                s <- keycodeToKeysym d c 0
                return (t, s)
  let setOption n = do
        let nextWs   = options `cycref` n
            syncW ws = windows $ view ws . unView'
        (t, s) <- io event
        if | t == keyPress   && s == keyNext  -> syncW nextWs >> setOption (n + 1)
           | t == keyPress   && s == keyPrev  -> syncW nextWs >> setOption (n - 1)
           | t == keyRelease && s `elem` mods ->
               syncW =<< gets (tag . workspace . current . windowset)
           | otherwise                        -> setOption n
  io $ grabKeyboard d root False grabModeAsync grabModeAsync currentTime
  windows $ view (options `cycref` 0) -- view the first ws
  setOption 1
  io $ ungrabKeyboard d currentTime
 where
  cycref :: [a] -> Int -> a
  cycref l i = l !! (i `mod` length l)

-- | Given an old and a new 'WindowSet', which is __exactly__ one
-- 'view' away from the old one, restore the workspace order of the
-- former inside of the latter.  This respects any new state that the
-- new 'WindowSet' may have accumulated.
unView :: forall i l a s sd. Eq i
       => StackSet i l a s sd -> StackSet i l a s sd -> StackSet i l a s sd
unView w0 w
  | currentTag w0 == currentTag w = w

  | v1 : vs <- visible w
  , currentTag w0 == (tag . workspace) v1
  = w { current = v1
      , visible = insertAt (commonPrefixV (visible w0) vs) (current w) vs }

  | h1 : hs <- hidden w
  , currentTag w0 == tag h1
  = w { current = (current w){ workspace = h1 }
      , hidden = insertAt (commonPrefixH (hidden w0) hs) (workspace (current w)) hs }

  | otherwise = w
 where
  commonPrefixV = commonPrefix `on` fmap (tag . workspace)
  commonPrefixH = commonPrefix `on` fmap tag

  insertAt :: Int -> x -> [x] -> [x]
  insertAt n x xs = let (l, r) = splitAt n xs in l ++ [x] ++ r

  commonPrefix :: Eq x => [x] -> [x] -> Int
  commonPrefix a b = length $ takeWhile id $ zipWith (==) a b

-- | Given some function that generates a list of workspaces from a
-- given 'WindowSet', switch to the first generated workspace.
toggleWindowSets :: (WindowSet -> [WorkspaceId]) -> X ()
toggleWindowSets genOptions = do
  options <- gets $ genOptions . windowset
  case options of
    []  -> return ()
    o:_ -> windows (view o)
