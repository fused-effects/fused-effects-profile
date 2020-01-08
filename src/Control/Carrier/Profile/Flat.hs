{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
module Control.Carrier.Profile.Flat
( -- * Profile carrier
  runProfile
, reportProfile
, execProfile
, ProfileC(ProfileC)
, Timing(..)
, renderTiming
, mean
, Timings(..)
, renderTimings
, reportTimings
  -- * Profile effect
, module Control.Effect.Profile
) where

import           Control.Algebra
import           Control.Carrier.Lift
import           Control.Carrier.Writer.Strict
import           Control.Effect.Profile
import           Control.Monad.IO.Class
import qualified Data.HashMap.Strict as HashMap
import           Data.List (sortOn)
import           Data.Ord (Down(..))
import           Data.Text (Text)
import           Data.Text.Prettyprint.Doc
import           Data.Text.Prettyprint.Doc.Render.Terminal
import           Data.Time.Clock
import           Numeric (showFFloat)
import           Prelude hiding (sum)
import           System.IO (stderr)

runProfile :: ProfileC m a -> m (Timings, a)
runProfile (ProfileC m) = runWriter m

reportProfile :: Has (Lift IO) sig m => ProfileC m a -> m a
reportProfile m = do
  (t, a) <- runProfile m
  a <$ reportTimings t

execProfile :: Functor m => ProfileC m a -> m Timings
execProfile = fmap fst . runProfile

newtype ProfileC m a = ProfileC { runProfileC :: WriterC Timings m a }
  deriving (Applicative, Functor, Monad, MonadFail, MonadIO)

instance (Has (Lift IO) sig m, Effect sig) => Algebra (Profile :+: sig) (ProfileC m) where
  alg = \case
    L (Measure l m k) -> do
      start <- sendM getCurrentTime
      (_, a) <- ProfileC (censor @Timings (const mempty) (listen @Timings (runProfileC m)))
      end <- sendM getCurrentTime
      ProfileC (tell (timing l (end `diffUTCTime` start)))
      k a
    R other -> ProfileC (send (handleCoercible other))
    where
    timing ls t = Timings (HashMap.singleton ls (Timing t t t 1))


data Timing = Timing
  { sum   :: !NominalDiffTime
  , min'  :: !NominalDiffTime
  , max'  :: !NominalDiffTime
  , count :: {-# UNPACK #-} !Int
  }

instance Semigroup Timing where
  Timing s1 mn1 mx1 c1 <> Timing s2 mn2 mx2 c2 = Timing (s1 + s2) (mn1 `min` mn2) (mx1 `max` mx2) (c1 + c2)

instance Monoid Timing where
  mempty = Timing 0 0 0 0

renderTiming :: Timing -> Doc AnsiStyle
renderTiming t@Timing{ min', max' } = table (map go fields) <> line
    where
    table = group . encloseSep (flatAlt "{ " "{") (flatAlt " }" "}") ", "
    fields =
      [ (annotate (colorDull Green) "min", prettyMS min')
      , (annotate (colorDull Green) "mean", prettyMS (mean t))
      , (annotate (colorDull Green) "max", prettyMS max')
      ]
    go (k, v) = k <> colon <+> v
    prettyMS = (<> annotate (colorDull White) "ms") . pretty . ($ "") . showFFloat @Double (Just 3) . (* 1000) . realToFrac

mean :: Timing -> NominalDiffTime
mean Timing{ sum, count } = sum / fromIntegral count


newtype Timings = Timings { unTimings :: HashMap.HashMap Text Timing }

instance Semigroup Timings where
  Timings t1 <> Timings t2 = Timings (HashMap.unionWith (<>) t1 t2)

instance Monoid Timings where
  mempty = Timings mempty

renderTimings :: Timings -> Doc AnsiStyle
renderTimings (Timings ts) = vsep (map go (sortOn (Down . mean . snd) (HashMap.toList ts))) where
  go (k, v) = annotate (color Green) (pretty k) <> pretty ':' <> softline <> renderTiming v

reportTimings :: Has (Lift IO) sig m => Timings -> m ()
reportTimings = sendM . renderIO stderr . layoutPretty defaultLayoutOptions . (<> line) . renderTimings
