{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DerivingVia #-}

module Control.Arrow.Rowar
  ( Product(..)
  , Tannen(..)
  )
where

import Control.Category
import Control.Arrow

import Control.Monad.Reader
import Data.Bifunctor.Tannen
import Data.Bifunctor.Product
import Data.Functor.Identity  -- Needed by the deriving via machinery
import Data.Typeable
import Data.Vinyl hiding ((<+>))
import GHC.Exts
import GHC.TypeLits

import Prelude hiding (id, (.))


-- data Altern f g a b where
--   AlternId :: AlternId f g a a
--   Altern   :: f a x -> g x y -> Altern f g y b -> Altern f g a b

-- runAltern :: (Arrow ar)
--           => (forall x y. f x y -> ar x y)
--           -> (forall x y. g x y -> ar x y)
--           -> Altern f g a b
--           -> ar a b
-- runAltern _ _ AlternId = arr id
-- runAltern runF runG (Altern f g r) =
--   runF f >>> runG g >>> runAltern runF runG r

-- instance Category (ASeq f g) where
--   id = AlternId
--   a . AlternId = a
--   a . Altern f g a' = Altern f g (a . a')  -- Problematic: quadratic complexity

-- instance (Arrow f, Arrow g) => Arrow (Altern f g) where
--   arr f = Altern (arr f) id AlternId
--   first (Altern f g r) = Altern (first f) (first g) (first r)

-- | The kind for all effects of arity 2
type Strand = * -> * -> *

-- | The kind for a type-level effect list
type Strands = [(Symbol, Strand)]

-- | The kind for records that will contain 'StrandRunner's
type TwineRec = ((Symbol, Strand) -> *) -> Strands -> *

type family Snd t where
  Snd '(a,b) = b

-- | A natural transformation on type constructors of two arguments.
type f ~> g = forall x y. f x y -> g x y

-- | Runs one strand (* -> * -> * effect) in another
newtype StrandRunner (sup::Strand) (strand::(Symbol,Strand)) = StrandRunner
  { runStrand :: Snd strand ~> sup }

-- | Constructs a free arrow out of several * -> * -> * effects ('Strand's) that
-- can be interlaced "on top" of an existing arrow @sup@ (for "support")
--
-- Note that it isn't supposed to be an "arrow transformer" (though it could be
-- used as such), @sup@ in most uses is supposed to remain polymorphic, it is
-- just exposed so constraints can be added on it
newtype Twine_ (record::TwineRec) (strands::Strands) (sup::Strand) a b =
  Twine
  { runTwine :: record (StrandRunner sup) strands -> sup a b }
  deriving (Category, Arrow, ArrowChoice, ArrowLoop, ArrowZero, ArrowPlus)
    via Reader (record (StrandRunner sup) strands) `Tannen` sup

type Twine = Twine_ ARec
type LooseTwine = Twine_ Rec

tightenTwine :: LooseTwine s sup a b -> Twine s sup a b
tightenTwine = undefined

loosenTwine :: Twine s sup a b -> LooseTwine s sup a b
loosenTwine = undefined
