{-# LANGUAGE Arrows #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}

import Control.Kernmantle.Rope
import Control.Arrow
import Data.Proxy

-- | The Console effect
data a `Console` b where
  GetLine :: () `Console` String
  PutLine :: String `Console` ()

-- | Run a Console effect in IO
interpConsole :: (rope `Entwines` '[IOStrand])
              => a `Console` b -> a `rope` b
interpConsole cmd = ioStrand $ case cmd of
  GetLine -> const getLine
  PutLine -> putStrLn . (">> "++)

-- | The File effect
data a `File` b where
  GetFile :: FilePath `File` String
  PutFile :: (FilePath, String) `File` ()

-- | Run a File effect in IO
interpFile :: (rope `Entwines` '[IOStrand])
            => a `File` b -> a `rope` b
interpFile cmd = ioStrand $ case cmd of
  GetFile -> readFile
  PutFile -> uncurry writeFile

type ProgArrow req a b = forall strands core.
  ( ArrowChoice core, LooseRope strands core `Entwines` req )
  => LooseRope strands core a b

-- | The Arrow program we will want to run
prog :: ProgArrow '[ '("console",Console), '("file",File) ] String ()
prog = proc name -> do
  strand #console PutLine -< "Hello, " ++ name ++ ". What file would you like to open?"
  fname <- strand #console GetLine -< ()
  contents <- if fname == ""
    then strand #console GetLine -< ()
    else strand #file GetFile -< fname
  strand #console PutLine -< contents

main = prog & entwine #console interpConsole
            & entwine #file interpFile
            & flip untwineIO "You"
