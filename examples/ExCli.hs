{-# LANGUAGE Arrows #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}


-- | In this example, we show how to make an effect that can expose options it
-- wants, then accumulate these options into a regular Parser (from
-- optparse-applicative) which builds a pipeline.

import Prelude hiding (id, (.))

import Control.Kernmantle.Rope
import Control.Arrow
import Control.Category
import Data.Functor.Compose
import Data.Profunctor.Cayley
import Options.Applicative
import Data.Char (toUpper)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8


data a `GetOpt` b where
  GetOpt :: String  -- ^ Name
         -> String  -- ^ Docstring
         -> Maybe String  -- ^ Default value
         -> GetOpt a String  -- ^ Returns final value

data a `FileAccess` b where
  ReadFile :: String  -- ^ File name
           -> FileAccess a BS.ByteString
  WriteFile :: String  -- ^ File name
            -> FileAccess BS.ByteString ()

type a ~~> b =
  AnyRopeWith '[ '("options", GetOpt)
               , '("files", FileAccess) ]
              '[Arrow] a b

pipeline :: () ~~> ()
pipeline = proc () -> do
  name     <- getOpt "name" "The user's name" $ Just "Yves" -< ()
  lastname <- getOpt "lastname" "The user's last name" $ Just "Pares" -< ()
  age      <- getOpt "age" "The user's age" Nothing -< ()
    -- This demonstrates early failure: if age isn't given, this pipeline won't
    -- even start
  cnt <- strand #files (ReadFile "user") -< ()
  let summary = "Your name is " ++ name ++ " " ++ lastname ++
                " and you are " ++ age ++ ".\n"
  strand #files (WriteFile "summary") -< BS8.pack summary <> cnt
  where
    getOpt n d v = strand #options $ GetOpt n d v

-- | The core effect we need to collect all our options and build the
-- corresponding CLI Parser. What we should really run once our strands of
-- effects have been evaluated.  Note that @CoreEff a b = Parser (a -> IO b)@
type CoreEff = Cayley Parser (Kleisli IO)

-- | Turns a GetOpt into an actual optparse-applicative Parser
interpretGetOpt :: GetOpt a b -> CoreEff a b
interpretGetOpt (GetOpt name docstring defVal) =
  Cayley $ Kleisli . const . return <$>
  let (docSuffix, defValField) = case defVal of
        Just v -> (". Default: "<>v, value v)
        Nothing -> ("", mempty)
  in strOption ( long name <> help (docstring<>docSuffix) <>
                 metavar (map toUpper name) <> defValField )

-- | An option string to get a filepath
fpParser :: String -> String -> Parser String
fpParser fname prefix = strOption
  ( long (prefix<>fname) <> help ("File bound to "<>fname<>". Default: "<>def)
    <> metavar "PATH" <> value def )
  where def = fname<>".txt"

-- | Turns a FileAccess into an option that requests a real filepath, and
-- performs the access (doesn't support accessing twice the same file for now)
interpretFileAccess :: FileAccess a b -> CoreEff a b
interpretFileAccess (ReadFile name) = Cayley $ f <$> fpParser name "read-"
  where f realPath = Kleisli $ const $ BS.readFile realPath
interpretFileAccess (WriteFile name) = Cayley $ f <$> fpParser name "write-"
  where f realPath = Kleisli $ BS.writeFile realPath

main :: IO ()
main = do
  Kleisli runPipeline <- execParser $ info (helper <*> interpretedPipeline) $
       header "A simple kernmantle pipeline"
    <> progDesc "Doesn't do much, but cares about you"
  runPipeline ()
  where
    Cayley interpretedPipeline =
      pipeline & loosen
               & entwine_ #options interpretGetOpt
               & entwine_ #files   interpretFileAccess
               & untwine
