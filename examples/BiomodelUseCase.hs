{-# LANGUAGE Arrows #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveGeneric #-}

-- | This example:
--
-- - creates an 'ODEModel' type
-- - describes a vanderpol model as an 'ODEModel'
-- - describes a simple chemical equation as a 'ChemicalModel'
-- - builds a pipeline exposing to the user the parameters of these models
--   and of the solver
-- - converts the chemical model to an 'ODEModel'
-- - solves the models, caching the results
-- - writes the results as CSV files (paths are exposed via CLI options)
-- - generates vega lite visualisations of the results
--
-- More generally this examples shows how to use kernmantle effects to
-- build all these features.
--
-- All the pipeline primitives present in this file are generic,
-- they could be reused as-is for different 'ODEModel's. See 'pipeline'.

import Prelude hiding (id, (.))

import Control.Kernmantle.Rope
import Control.Arrow
import Control.Category
import Control.DeepSeq (deepseq)
import Control.Monad.IO.Class
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Writer.Strict
import qualified Data.CAS.ContentHashable as CS
import qualified Data.CAS.ContentStore as CS
import qualified Data.CAS.RemoteCache as Remote
import Data.Csv.HMatrix
import Data.Functor.Identity (Identity)
import Data.Functor.Compose
import Data.List (intercalate)
import Data.Maybe (fromJust)
import Data.Profunctor
import Data.Profunctor.Cayley
import Data.Store (Store)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Encoding as LTE
import Data.Typeable (Typeable, typeOf)
import Options.Applicative
import Data.Char (toUpper)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Char8 as BS8
import GHC.Generics (Generic)
import qualified Data.Map.Strict as M

import qualified Numeric.Sundials.ARKode.ODE as ARK
import qualified Numeric.Sundials.CVode.ODE  as CV
import qualified Numeric.LinearAlgebra as L
import           Numeric.Sundials.Types

import qualified Graphics.Vega.VegaLite as VL

import Path
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

--------------------------------------------------------------------------------
-- ODE models

type ODESystem = Double -> [Double] -> [Double]
  -- ^ The RHS of the system, taking absolute time in input (useful if our
  -- function contains time-dependent parameters).  Invariant: if @f ::
  -- ODESystem@, then in @y = f t x@, @x@ and @y@ should always have the same
  -- length

type InitConds = [Double]
  -- ^ Initial conditions. Should have the same length than the inputs of the
  -- 'ODESystem'

data ODEModel params result = ODEModel
  { odeSystem :: params -> ODESystem  -- ^ Given the model params, build an ODESystem
  , odePostProcess :: L.Vector Double -> L.Matrix Double -> result
      -- ^ Given the time steps used and the solving results (with first column
      -- being time), compute the final result
  , odeVarNames :: [T.Text]  -- ^ Names of the variables (and of the columns of the matrix)
  , odeInitConds :: InitConds -- ^ Initial values of the variables
  , odeModelId :: String -- ^ And identifier used for caching purposes
  }
instance Profunctor ODEModel where
  dimap f g mdl = mdl{odeSystem = \p -> odeSystem mdl (f p)
                     ,odePostProcess = \t m -> g (odePostProcess mdl t m)}
-- | The hash takes into account the model Id and initial conditions
instance (Monad m) => CS.ContentHashable m (ODEModel params a) where
  contentHashUpdate ctx mdl =
    CS.contentHashUpdate ctx (odeInitConds mdl, odeModelId mdl)

--------------------------------------------------------------------------------
-- Chemical models

-- | The name of the chemical element
type Element = String

-- | A dynamical system determined by a chemical reaction.
data ChemicalModel = ChemicalModel
  { -- | The left-hand side of the chemical reaction.
    chemicalLeft      :: M.Map Element Int
    -- | The right-hand side of the chemical reaction.
  , chemicalRight     :: M.Map Element Int
    -- | The initial quantities (in moles) of each element
  , chemicalInitConds :: M.Map Element Double
    -- | The identity of the system, for hashing purposes
  , chemicalModelId   :: String
  } deriving (Show)

-- | Change the direction of arrows for the chemical reaction system.
reverseChemicalModel :: ChemicalModel -> ChemicalModel
reverseChemicalModel cm@(ChemicalModel {chemicalLeft=l, chemicalRight=r}) =
  cm {chemicalLeft=r, chemicalRight=l}

-- | Given reaction velocities in each sense, convert a chemical system into a
-- differential equation system for the quantity of each element.
--
-- The model parameters are the reaction rates (from left to right and from
-- right to left)
chemicalToODEModel :: ChemicalModel
                   -> ODEModel (Double,Double) (L.Vector Double, L.Matrix Double)
chemicalToODEModel chemMdl =
  ODEModel { odeSystem = odeSystem
           , odePostProcess = (,)
           , odeVarNames = map T.pack vars
           , odeInitConds = ics
           , odeModelId = chemicalModelId chemMdl }
  where
    (vars, ics) = unzip $ M.toList $ M.intersectionWith (\_ ic -> ic)
      (M.union (chemicalLeft chemMdl) (chemicalRight chemMdl))
      (chemicalInitConds chemMdl)
    
    odeSystem (lr,rl) _t xs =
      zipWith combine (go chemMdl xs)
                      (go (reverseChemicalModel chemMdl) xs)
      where
        combine x y = lr * x + rl * y
    
    system m xs = product (M.intersectionWith term is qs)
      where
        keys = M.keys m
        is = fmap fst m
            -- this assumes that variables are in aphabetical order
        qs = M.fromAscList $ zipWith (,) keys xs
        fact n = fromIntegral $ product [1..n]
        term i q = q ** fromIntegral i / fromIntegral (fact i)

    go (ChemicalModel{chemicalLeft=l, chemicalRight=r}) xs = fmap (* system m xs) v
      where
        m :: M.Map Element (Int,Int)
        m =
          M.unionWith
          (\(x1,y1) (x2,y2) -> (x1 + x2, y1 + y2))
          (fmap (\x -> (x,0)) l)
          (fmap (\y -> (0,y)) r)

        v :: [Double]
        v = M.elems $ fmap (\(i,o) -> fromIntegral (o - i)) m

--------------------------------------------------------------------------------
-- Example models

--------------------------------------------------------------------------------
-- Effect definition

-- | An effect to simulate an ODE system
data SimulateODE a b where
  SimulateODE :: (CS.ContentHashable Identity p, Store r)
                 -- We'll hash the model and serialize its result for caching purposes
              => ODEModel p r
              -> SimulateODE p r
    -- ^ Given a model of N variables to solve, simulates it and returns a
    -- matrix with N+1 columns, first column being the time steps

-- | An effect to ask for some parameter's value
data GetOpt a b where
  -- | Get a raw string option
  GetOpt :: (Show b, Typeable b, CS.ContentHashable Identity b)
             -- So we can show the default value and its type, and add the
             -- selected value to the cache context
         => ReadM b  -- ^ How to parse the option
         -> String  -- ^ Name
         -> String  -- ^ Docstring
         -> Maybe b  -- ^ Default value
         -> GetOpt a b  -- ^ Returns final value
  -- | Ask to select between alternatives
  Switch :: (CS.ContentHashable Identity b)
         => (String, String, b) -- ^ Name and docstring of default
         -> [(String, String, b)]
            -- ^ Names and docstrings of alternatives
         -> GetOpt a b

-- | An effect to read or write a file
data FileAccess a b where
  ReadFile :: String  -- ^ File name, without extension
           -> String  -- ^ File extension
           -> FileAccess a BS.ByteString
  WriteFile :: String  -- ^ File name, without extension
            -> String  -- ^ File extension
            -> FileAccess LBS.ByteString ()

-- | The Console effect
data Logger a b where
  Log :: Logger String ()

data SomeHashable where
  SomeHashable ::
    (CS.ContentHashable Identity a) => a -> SomeHashable
instance CS.ContentHashable Identity SomeHashable where
  contentHashUpdate ctx (SomeHashable a) = CS.contentHashUpdate ctx a
type CacheContext = [SomeHashable]

-- | An class to cache part of the pipeline
class Cacheable eff where
  caching :: CS.Cacher (CacheContext,a) b -> eff a b -> eff a b

-- | Any core that has caching provides it to the rope:
instance (Cacheable core) => Cacheable (Rope r m core) where
  caching = mapRopeCore . caching

-- | Used by option parser and logger, to know where the option and line to log
-- comes from
type Namespace = [String]

-- | If an effect can hold a namespace.
class Namespaced eff where
  -- | Add an element to the namespace
  addToNamespace :: String -> eff a b -> eff a b

-- | How to add a namespace to tasks in a Rope. Several effects require to be
-- interpreted in some @Cayley (Reader Namespace)@ because they need a namespace
-- to construct their effects
instance Namespaced (Cayley (Reader Namespace) eff) where
  addToNamespace n (Cayley eff) = Cayley (local (++[n]) eff)

-- | Any rope whose core has namespacing has namespacing too
instance (Namespaced core) => Namespaced (Rope r m core) where
  addToNamespace = mapRopeCore . addToNamespace

-- | For options parsed by IsString class
getStrOpt n d v = strand #options $ GetOpt str n d v

-- | For options parsed by Read class
getOpt n d v = strand #options $ GetOpt auto n d v

-- | An Applicative version of 'getOpt'
getOptA n d v = ArrowMonad $ getOpt n d v

-- | Unwrap an applicative to get back an arrow
appToArrow (ArrowMonad a) = a

-- | Generate a vega-lite visualisation of the results of a simulation
genViz :: AnyRopeWith
  '[ '("options", GetOpt) ]
  '[Arrow]
   (L.Vector Double, [T.Text], L.Matrix Double) VL.VegaLite
genViz = proc (timeVec, colNames, mtx) -> do
  let
    varCols = L.toColumns mtx
    dat = VL.dataFromColumns []
      . VL.dataColumn "Time" (VL.Numbers $ L.toList timeVec)
      . foldr (.) id
        (map (\(cn,ys) -> VL.dataColumn cn (VL.Numbers $ L.toList ys)) $
             zip colNames varCols)
    trans = VL.transform
      . VL.foldAs colNames "Variable" "Value"
        -- Creates two new columns for each variable of the model, so we can use
        -- the variable name and value resp. for color encoding and Y-position
        -- encoding
    enc = VL.encoding
      . VL.position VL.X [ VL.PName "Time", VL.PmType VL.Quantitative ]
      . VL.position VL.Y [ VL.PName "Value", VL.PmType VL.Quantitative ]
      . VL.color         [ VL.MName "Variable", VL.MmType VL.Nominal ]
  (w,h) <- getOpt "viz-size" "(width,height) of the visualisation" (Just (800,800)) -< ()
  returnA -< VL.toVegaLite [ trans [], dat [], enc [], VL.mark VL.Line []
                           , VL.height h, VL.width w ]

data SolTimes = SolTimes { solStart      :: Double
                         , solEnd        :: Double
                         , solTimepoints :: Int }
  deriving (Generic)
instance (Monad m) => CS.ContentHashable m SolTimes

data ODESolvingAlgorithm = CVode | ARKode
  deriving (Show, Generic)
instance (Monad m) => CS.ContentHashable m ODESolvingAlgorithm

solveWith CVode = CV.odeSolve
solveWith ARKode = ARK.odeSolve

expandSolTimes :: SolTimes -> L.Vector Double
expandSolTimes st =
  L.linspace (solTimepoints st) (solStart st, solEnd st)

--------------------------------------------------------------------------------
-- Effect interpretation

-- | Solve an ODE model in any Arrow Rope that can cache computations, get
-- options, do logging and write files. Writes the results to csv files and
-- their vega-lite visualizations to html files (the folder to write in will be
-- determined by the current namespace).
interpretSimulateODE
  :: SimulateODE a b
  -> AnyRopeWith '[ '("options", GetOpt), '("logger",Logger), '("files",FileAccess) ]
                 '[Arrow] a b
-- | Solve an ODE model in any Rope that has a GetOpt effect
interpretSimulateODE (SimulateODE mdl) = proc params -> do
  -- We ask for an override of the initial conditions:
  ics <- getOpt "ics" ("Initial conditions for variables "++show (odeVarNames mdl)) (Just $ odeInitConds mdl) -< ()
  -- We ask for some parameters related to the simulation process:
  times <- appToArrow $ SolTimes
    <$> getOptA "start" "T0 of simulation" (Just 0)
    <*> getOptA "end" "Tmax of simulation" (Just 50)
    <*> getOptA "timepoints" "Num timepoints of simulation" (Just 1000) -< ()
  -- We ask for the solving algorithm to use:
  solvingAlg <- strand #options $ Switch
    ("cv", "Solve with CVode algorithm. See https://computing.llnl.gov/projects/sundials/cvode", CVode)
    [("ark", "Solve with ARKode algorithm. See https://computing.llnl.gov/projects/sundials/arkode", ARKode)]
    -< ()
  -- Finally we can solve the system:
  strand #logger Log -< "Start solving"
  let timeVec = expandSolTimes times
      resMtx = solveWith solvingAlg (odeSystem mdl params) ics timeVec
  strand #logger Log -< resMtx `deepseq` "Done solving"
  strand #files $ WriteFile "res" "csv" -<
    mkHeader (odeVarNames mdl) <> encodeMatrix (L.asColumn timeVec L.||| resMtx)
  -- We write the time vector as first column in the CSV
  viz <- genViz -< (timeVec, odeVarNames mdl, resMtx)
  strand #files $ WriteFile "viz" "html" -< LTE.encodeUtf8 $ VL.toHtml $ viz
  returnA -< odePostProcess mdl timeVec resMtx
  where
    mkHeader vars = LTE.encodeUtf8 $ LT.fromStrict $
      "Time," <> T.intercalate "," vars <> "\r\n"

-- | Builds a namespace prefix, with some beginning, separator and ending. If
-- namespace is empty, returns the empty string.
nsPrefix :: Namespace -> String -> String -> String -> String
nsPrefix [] _ _ _ = ""
nsPrefix ns beg sep end = beg <> intercalate sep ns <> end

-- | Run a Console effect in any effect that can access a namespace and Kleisli m where m is a
-- MonadIO
interpretLogger :: (HasKleisliIO m eff)
                => Logger a b -> Cayley (Reader Namespace) eff a b
interpretLogger Log =
  Cayley $ reader $ \ns ->  -- We need the namespace as for each line logged, we
                            -- want to print in which namespace it was logged
    liftKleisliIO $ putStrLn . (nsPrefix ns "" "." ">> "<>)

-- | Weave a FileAccess into any rope with our CoreEff that can access options
-- (to give the option to rebind the default file path), a logger (to log when a
-- result has been written), and a MonadIO (to performs the access).
--
-- Needs the namespace to know the default paths to which we should write/read
-- the files. When writing, creates the directory tree if some are missing.
interpretFileAccess
  :: (MonadIO m)
  => Namespace  -- ^ Will be used as folders
  -> FileAccess a b
  -> AnyRopeWith '[ '("options",GetOpt), '("logger",Logger) ] '[Arrow, HasKleisli m] a b
interpretFileAccess ns (ReadFile name ext) =
  getStrOpt ("read-"<>name) ("File to read "<>name<>" from")
                            (Just $ nsPrefix ns "" "/" "/" <> name<>"."<>ext)
  >>>
  liftKleisliIO BS.readFile
interpretFileAccess ns (WriteFile name ext) = proc content -> do
  realPath <- getStrOpt ("write-"<>name) ("File to write "<>name<>" to")
                                         (Just $ nsPrefix ns "" "/" "/" <> name<>"."<>ext) -< ()
  liftKleisliIO id -< do
    createDirectoryIfMissing True $ takeDirectory realPath
    LBS.writeFile realPath content
  strand #logger Log -< "Wrote file "<>realPath

--------------------------------------------------------------------------------
-- Pipeline definition

-- | The vanderpol 'ODEModel'
vanderpol :: ODEModel Double ()
vanderpol =
  ODEModel (\mu _t [x,v] -> [v, -x + mu * v * (1-x*x)])
           (\_ _ -> ())  -- We don't want any post-processing
           ["x","v"]
           [1,0]
           "vanderpol0.1"

-- | A simple chemical equation, which we turn into an 'ODEModel'
chemical :: ODEModel Double ()
chemical =  -- Input param is the reaction rate and we don't want post-processing
  dimap (\k -> (k, k/2)) (const ()) $
    chemicalToODEModel $
      ChemicalModel (M.fromList [("H20",1)])
                    (M.fromList [("H+",2), ("O-",1)])
                    (M.fromList [("H20",1), ("H+",0), ("O-",0)])
                    "chemical0.1"

-- | The final pipeline to run. It solves two models to show that the same
-- tooling can be used to solve 2 models in the same pipeline with no risks of
-- options or files conflicting (thanks to namespaces)
pipeline =
  log "Beginning pipeline"
  >>>
  addToNamespace "vanderpol"
    (getOpt "mu" "µ parameter" (Just 2)
     >>>
     caching (CS.defaultCacherWithIdent 1000)
       -- Any option, any change as to where to write simulation results will
       -- invalidate the cache, and make the content of the 'caching' block to
       -- be re-executed
       (strand #ode (SimulateODE vanderpol)))
  >>> 
  addToNamespace "chemical"
    (getOpt "k" "Left-to-right reaction rate" (Just 2)
     >>>
     caching (CS.defaultCacherWithIdent 1001)
       (strand #ode (SimulateODE chemical)))
  >>>
  log "Pipeline finished"
  where log s = arr (const s) >>> strand #logger Log

--- * END OF PIPELINE

--------------------------------------------------------------------------------
-- Pipeline interpretation

-- | The core effect we need.
--
-- It looks complicated but is actually completely equivalent to:
-- CoreEff a b = Namespace -> Parser (CacheContext, a -> CS.ContentStore -> IO b)
type CoreEff =
  -- These three first layers run when we load the pipeline, they will be
  -- stripped before execution:
  Cayley (Reader Namespace)  -- Get the namespace we are in
    (Cayley Parser  -- Get the CLI options, whose name is conditionned on the
                    -- current namespace
      (Cayley (Writer CacheContext) -- Accumulate the context needed to know
                                    -- what to take into account to perform
                                    -- caching
        -- The following layers are the ones that actually run when we
        -- execute the pipeline:
        (Kleisli  -- Kleisli is the frontier between load time and runtime
          (ReaderT CS.ContentStore -- Get the content store, to cache
                                   -- computation at runtime
            IO))))

-- | Creates a Writer that builds the action that returns the chosen option
-- value when the pipeline runs AND populates the 'CacheContext'
reportCacheContext opt =
  Cayley $ writer (arr $ const opt, [SomeHashable opt])

-- | Given a Namespace to generate CLI flag names, turns a GetOpt into an actual
-- optparse-applicative Parser, and adds the value of the option given by the
-- user to the CacheContext
--
-- interpretGetOpt is the only weaver that needs access to basically every layer
-- of CoreEff.
interpretGetOpt :: GetOpt a b
                -> CoreEff a b
interpretGetOpt (GetOpt parser name docstring defVal) =
  Cayley $ reader $ \ns ->  -- We need the namespace as we want to prefix option
                            -- flags with it
    Cayley $ reportCacheContext <$>
      let (docSuffix, defValField) = case defVal of
            Just v -> (". Default: "<>show v, value v)
            Nothing -> ("", mempty)
      in option parser (   long (nsPrefix ns "" "-" "-" <> name)
                        <> help (nsPrefix ns "In " "." ": "<>docstring<>docSuffix)
                        <> metavar (show $ typeOf $ fromJust defVal) <> defValField )
interpretGetOpt (Switch (defName,defDocstring,defVal) alts) =
  Cayley $ reader $ \ns ->
    Cayley $ reportCacheContext <$>
      let defFlag =
            flag defVal defVal (   long (nsPrefix ns "" "-" "-" <> defName)
                                <> help (nsPrefix ns "In " "." ": "<> defDocstring) )
          toFlag' (name, docstring, val) =
            flag' val (   long (nsPrefix ns "" "-" "-" <> name)
                       <> help (nsPrefix ns "In " "." ": "<>docstring) )
      in foldr (<|>) defFlag (map toFlag' alts)

-- | When we want to perform a cached task, we need to access the current
-- CacheContext before, so we need to do some newtype juggling
instance Cacheable CoreEff where
  caching c = fmapC (fmapC readCacheContextAndExec)
    where
      fmapC g (Cayley app) = Cayley $ fmap g app
      readCacheContextAndExec (Cayley w) =
        Cayley $ writer $ case runWriter w of
          (Kleisli act, cacheContext) ->
            (Kleisli $ \i -> do
              store <- ask
              CS.cacheKleisliIO (Just 1) c Remote.NoCache store
                                (act . snd) (cacheContext,i)
            ,cacheContext)

main :: IO ()
main = do
  let interpretFileAccess' toCore fileAccessEffect =
        -- We need to get the namespace to invoke 'interpretFileAccess'
        Cayley $ reader $ \ns ->
          runReader (runCayley $ toCore $ interpretFileAccess ns fileAccessEffect) ns
      Cayley namespacedPipelineParser =
          pipeline & loosen
            & entwine  #ode     (.interpretSimulateODE)
               -- interpretSimulateODE needs #logger and #options, so it must be
               -- entwined before them
            & entwine  #files   interpretFileAccess'
               -- interpretFileAccess needs #logger and #options, so it must be
               -- entwined before them
            & entwine_ #logger  interpretLogger
            & entwine_ #options interpretGetOpt
            & untwine
      Cayley pipelineParser = runReader namespacedPipelineParser []
  Cayley runPipelineW <- execParser $ info (helper <*> pipelineParser) $
         header "A kernmantle pipeline solving a biomodel"
  let Kleisli runPipeline = fst $ runWriter runPipelineW
  CS.withStore [absdir|/tmp/_store|] $ runReaderT $ runPipeline ()
  return ()
