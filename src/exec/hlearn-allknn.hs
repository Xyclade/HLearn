{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}

import Control.DeepSeq
import Control.Monad
import Data.Csv
import Data.List
import Data.Maybe
import qualified Data.Map.Strict as Map
-- import qualified Data.HashMap.Strict as Map
import qualified Data.Params as P
import Data.Params.Vector
import Data.Params.PseudoPrim
import qualified Data.Params.Vector.Unboxed as VPU
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as VM
import qualified Data.Vector.Generic as VG
import qualified Data.Vector.Generic.Mutable as VGM
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Unboxed.Mutable as VUM
import qualified Data.Vector.Primitive as VP
import qualified Data.Vector.Primitive.Mutable as VPM
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Storable.Mutable as VSM
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.Vector.Algorithms.Intro as Intro
import Numeric
import System.Console.CmdArgs.Implicit
import System.IO

import Test.QuickCheck hiding (verbose,sample)
import Control.Parallel.Strategies

import qualified Control.ConstraintKinds as CK
import HLearn.Algebra hiding (Frac (..))
import HLearn.DataStructures.CoverTree
import HLearn.DataStructures.SpaceTree
import HLearn.DataStructures.SpaceTree.Algorithms.NearestNeighbor
import HLearn.DataStructures.SpaceTree.Algorithms.RangeSearch
import HLearn.DataStructures.SpaceTree.DualTreeMonoids
import qualified HLearn.DataStructures.StrictList as Strict
import qualified HLearn.DataStructures.StrictVector as Strict
import HLearn.Metrics.Lebesgue
import HLearn.Metrics.Mahalanobis
import HLearn.Metrics.Mahalanobis.Normal
import HLearn.Models.Distributions

import Data.Params

import Paths_HLearn
import Data.Version

import LoadData
import Timing 
import HLearn.UnsafeVector

type DP = L2 VU.Vector Float
type Tree = AddUnit (CoverTree' (13/10) V.Vector VU.Vector) () DP
 
-- type DP = L2' (VPU.Vector P.Automatic) Float
-- type Tree = AddUnit (CoverTree' (13/10) V.Vector (VPU.Vector P.RunTime)) () DP
-- 
-- instance FromRecord (VPU.Vector P.Automatic Float) where
--     parseRecord r = fmap VG.convert (parseRecord r :: Parser (V.Vector Float))
-- 
-- instance PseudoPrim (v a) => PseudoPrim (L2' v a) where
-- 
-- instance CK.Functor (VPU.Vector r) where
--     type FunctorConstraint (VPU.Vector r) a = VG.Vector (VPU.Vector r) a
--     fmap = VG.map
-- 
-- instance CK.Foldable (VPU.Vector r) where
--     type FoldableConstraint (VPU.Vector r) a = VG.Vector (VPU.Vector r) a
--     foldl' = VG.foldl'
--     foldr' = VG.foldr'
-- 
-- instance VG.Vector (VPU.Vector r) a => FromList (VPU.Vector r) a where
--     fromList = VG.fromList
--     toList = VG.toList
-- 
-- instance 
--     ( Param_len (VPU.Vector P.RunTime a)
--     , PseudoPrim a
--     ) => Monoid (VPU.Vector P.RunTime a) where
--     mempty = VG.empty
--     mappend a b = a -- VG.convert $ (VG.convert a :: V.Vector a) `mappend` (VG.convert b)

-------------------------------------------------------------------------------
-- command line parameters

data Params = Params
    { k                 :: Int
    , kForceSlow        :: Bool

    , reference_file    :: Maybe String 
    , query_file        :: Maybe String
    , distances_file    :: String
    , neighbors_file    :: String 

    , train_sequential  :: Bool
    , train_monoid      :: Bool
    , cache_dists       :: Bool
    , pca_data          :: Bool
    , varshift_data     :: Bool
    , searchEpsilon     :: Float

    , packMethod        :: PackMethod
    , sortMethod        :: SortMethod

    , verbose           :: Bool
    , debug             :: Bool
    } 
    deriving (Show, Data, Typeable)

data PackMethod
    = NoPack
    | PackCT
    | PackCT2
    | PackCT3
    deriving (Eq,Read,Show,Data,Typeable)

data SortMethod
    = NoSort
    | NumDP_Distance
    | NumDP_Distance'
    | Distance_NumDP
    | Distance_NumDP'
    deriving (Eq,Read,Show,Data,Typeable)

allknnParams = Params 
    { k              = 1 
                    &= help "Number of nearest neighbors to find" 

    , reference_file = def 
                    &= help "Reference data set in CSV format" 
                    &= typFile

    , query_file     = def 
                    &= help "Query data set in CSV format" 
                    &= typFile 

    , distances_file = "distances_hlearn.csv" 
                    &= help "File to output distances into" 
                    &= typFile

    , neighbors_file = "neighbors_hlearn.csv" 
                    &= help "File to output the neighbors into" 
                    &= typFile

    , searchEpsilon   = 0
                    &= help ""
                    &= groupname "Approximations"

    , packMethod     = PackCT
                    &= help "Specifies which method to use for cache layout of the covertree"
                    &= groupname "Tree structure optimizations"

    , sortMethod     = NumDP_Distance
                    &= help "What order should the children be sorted in?"

    , kForceSlow     = False
                    &= help "Don't use precompiled k function; use the generic one"

    , train_sequential = False
                    &= help "don't train the tree in parallel; this may *slightly* speed up the nearest neighbor search at the expense of greatly slowing tree construction"

    , train_monoid   = False
                    &= help "train using the (asymptotically faster, but in practice slower) monoid algorithm"

    , cache_dists    = False
                    &= help "pre-calculate the maximum distance from any node dp to all of its children; speeds up queries at the expense of O(n log n) overhead"

    , pca_data       = False 
                    &= groupname "Data Preprocessing" 
                    &= help "Rotate the data points using the PCA transform.  Speeds up nearest neighbor searches, but computing the PCA can be expensive in many dimensions."
                    &= name "pca"
                    &= explicit

    , varshift_data  = False 
                    &= help "Sort the attributes according to their variance.  Provides almost as much speed up as the PCA transform during neighbor searches, but much less expensive in higher dimensions." 
                    &= name "varshift"
                    &= explicit

    , verbose        = False 
                    &= help "Print tree statistics (takes some extra time)" 
                    &= groupname "Debugging"

    , debug          = False 
                    &= help "Test created trees for validity (takes lots of time)" 
                    &= name "runtests"
                    &= explicit
    }
    &= summary ("HLearn k-nearest neighbor, version " ++ showVersion version)

-------------------------------------------------------------------------------
-- main

main = do
    -- cmd line args
    params <- cmdArgs allknnParams

    let checkfail x t = if x then error t else return ()
    checkfail (reference_file params == Nothing) "must specify a reference file"
    checkfail (searchEpsilon params < 0) "search epsilon must be >= 0"

    if kForceSlow params || k params > 3
        then do
            putStrLn "WARNING: using slow version of k"
            apWith1Param' 
                (undefined :: NeighborList RunTime DP)
                _k
                (k params) 
                (runit params (undefined::Tree))
                (undefined :: NeighborList RunTime DP)
        else case k params of 
            1 -> runit params (undefined :: Tree) (undefined :: NeighborList (Static 1) DP)
            2 -> runit params (undefined :: Tree) (undefined :: NeighborList (Static 2) DP)
            3 -> runit params (undefined :: Tree) (undefined :: NeighborList (Static 3) DP)
            4 -> runit params (undefined :: Tree) (undefined :: NeighborList (Static 4) DP)
            5 -> runit params (undefined :: Tree) (undefined :: NeighborList (Static 5) DP)
            100 -> runit params (undefined :: Tree) (undefined :: NeighborList (Static 100) DP)

{-# SPECIALIZE runit :: Params -> Tree -> NeighborList (Static 1) DP -> IO () #-}
-- {-# SPECIALIZE runit :: Params -> Tree -> NeighborList (Static 2) DP -> IO () #-}
-- {-# SPECIALIZE runit :: Params -> Tree -> NeighborList (Static 3) DP -> IO () #-}
-- {-# SPECIALIZE runit :: Params -> Tree -> NeighborList (Static 4) DP -> IO () #-}
-- {-# SPECIALIZE runit :: Params -> Tree -> NeighborList (Static 5) DP -> IO () #-}
-- {-# SPECIALIZE runit :: Params -> Tree -> NeighborList (Static 100) DP -> IO () #-}
-- {-# SPECIALIZE runit :: Param_k (NeighborList RunTime DP) => Params -> Tree -> NeighborList RunTime DP -> IO ()#-}

-- {-# INLINE runit #-}
runit :: forall k tree base childContainer nodeVvec dp ring. 
    ( MetricSpace dp
    , Ord dp
--     , KnownNat k
    , ViewParam Param_k (NeighborList k dp)
    , Show dp
    , Show (Scalar dp)
    , NFData dp
    , NFData (Scalar dp)
    , RealFloat (Scalar dp)
    , FromRecord dp 
    , VU.Unbox (Scalar dp)
--     , Param_len (VPU.Vector P.RunTime (L2' (VPU.Vector P.Automatic) Float))
    , dp ~ DP
    ) => Params 
      -> AddUnit (CoverTree' base childContainer nodeVvec) () dp 
      -> NeighborList k dp 
      -> IO ()
runit params tree knn = do
    
    -- build reference tree
    let dataparams = DataParams
            { datafile = fromJust $ reference_file params
            , labelcol = Nothing
            , pca      = pca_data params
            , varshift = varshift_data params
            }
    rs <- loaddata dataparams

    let reftree = 
            ( if train_sequential params then id else parallel )
            ( if train_monoid params then trainMonoid else trainInsert ) 
            rs :: Tree
    timeIO "building reference tree" $ return reftree

    let reftree_sort = case sortMethod params of
            NoSort -> unUnit reftree
            NumDP_Distance  -> sortChildren cmp_numdp_distance  $ unUnit reftree 
            NumDP_Distance' -> sortChildren cmp_numdp_distance' $ unUnit reftree 
            Distance_NumDP  -> sortChildren cmp_distance_numdp  $ unUnit reftree 
            Distance_NumDP' -> sortChildren cmp_distance_numdp' $ unUnit reftree 
    timeIO "sorting children" $ return reftree_sort

    let reftree_prune = case packMethod params of
            NoPack -> reftree_sort
            PackCT -> packCT $ reftree_sort
            PackCT2 -> packCT2 20 $ reftree_sort
            PackCT3 -> packCT3 $ reftree_sort
    timeIO "packing reference tree" $ return reftree_prune

    let reftree_cache = if cache_dists params 
            then setMaxDescendentDistance reftree_prune
            else reftree_prune
    time "caching distances" $ reftree_cache

    let reftree_final = reftree_cache

    -- verbose prints tree stats
    if verbose params 
        then do
            putStrLn ""
            printTreeStats "reftree      " $ unUnit reftree 
            printTreeStats "reftree_prune" $ reftree_final
        else return ()

    -- build query tree
    (querytree,qs) <- case query_file params of
        Nothing -> return $ (reftree_final,rs)
        Just qfile -> do
            qs <- loaddata $ dataparams { datafile = qfile }
            let qtree = train qs :: Tree
            timeIO "building query tree" $ return qtree
            let qtree_prune = packCT $ unUnit qtree
            timeIO "packing query tree" $ return qtree_prune
            return (qtree_prune,qs)

    -- do knn search
    let result = parFindEpsilonNeighborMap 
            ( searchEpsilon params ) 
            ( DualTree 
                ( reftree_final ) 
                ( querytree )
            ) 
            :: NeighborMap k DP

    res <- timeIO "computing parFindNeighborMap" $ return result

    -- output to files
    let qs_index = Map.fromList $ zip (VG.toList qs) [0::Int ..]
        rs_index = Map.fromList $ zip (VG.toList rs) [0::Int ..]

    timeIO "outputing distance" $ do
        hDistances <- openFile (distances_file params) WriteMode
        sequence_ $ 
            map (hPutStrLn hDistances . concat . intersperse "," . map (\x -> showEFloat (Just 10) x "")) 
            . Map.elems 
            . Map.mapKeys (\k -> fromJust $ Map.lookup k qs_index) 
            . Map.map (map neighborDistance . getknnL) 
            $ nm2map res 
        hClose hDistances
  
    timeIO "outputing neighbors" $ do
        hNeighbors <- openFile (neighbors_file params) WriteMode
        sequence_ $ 
            map (hPutStrLn hNeighbors . init . tail . show)
            . Map.elems 
            . Map.map (map (\v -> fromJust $ Map.lookup v rs_index)) 
            . Map.mapKeys (\k -> fromJust $ Map.lookup k qs_index) 
            . Map.map (map neighbor . getknnL) 
--             $ Map.fromList $ V.toList $ V.imap (\i x -> (stNodeV querytree VG.! i,x)) res 
--             $ Map.fromList $ zip (stToList querytree) (Strict.strictlist2list res)
            $ nm2map res 
        hClose hNeighbors
    -- end
    putStrLn "end"

-- printTreeStats :: String -> Tree -> IO ()
printTreeStats str t = do
    putStrLn (str++" stats:")
    putStr (str++"  stNumDp..............") >> hFlush stdout >> putStrLn (show $ stNumDp t) 
    putStr (str++"  stNumNodes...........") >> hFlush stdout >> putStrLn (show $ stNumNodes t) 
    putStr (str++"  stNumLeaves..........") >> hFlush stdout >> putStrLn (show $ stNumLeaves t) 
    putStr (str++"  stNumGhosts..........") >> hFlush stdout >> putStrLn (show $ stNumGhosts t) 
    putStr (str++"  stNumGhostSingletons.") >> hFlush stdout >> putStrLn (show $ stNumGhostSingletons t) 
    putStr (str++"  stNumGhostLeaves.....") >> hFlush stdout >> putStrLn (show $ stNumGhostLeaves t) 
    putStr (str++"  stNumGhostSelfparent.") >> hFlush stdout >> putStrLn (show $ stNumGhostSelfparent t) 
    putStr (str++"  stAveGhostChildren...") >> hFlush stdout >> putStrLn (show $ mean $ stAveGhostChildren t) 
    putStr (str++"  stMaxNodeV...........") >> hFlush stdout >> putStrLn (show $ stMaxNodeV t) 
    putStr (str++"  stAveNodeV...........") >> hFlush stdout >> putStrLn (show $ mean $ stAveNodeV t) 
    putStr (str++"  stMaxChildren........") >> hFlush stdout >> putStrLn (show $ stMaxChildren t) 
    putStr (str++"  stAveChildren........") >> hFlush stdout >> putStrLn (show $ mean $ stAveChildren t) 
    putStr (str++"  stMaxDepth...........") >> hFlush stdout >> putStrLn (show $ stMaxDepth t) 
    putStr (str++"  stNumSingletons......") >> hFlush stdout >> putStrLn (show $ stNumSingletons t) 
    putStr (str++"  stExtraLeaves........") >> hFlush stdout >> putStrLn (show $ stExtraLeaves t) 

    putStrLn (str++" properties:")
    putStr (str++"  covering...............") >> hFlush stdout >> putStrLn (show $ property_covering $ UnitLift t) 
    putStr (str++"  leveled................") >> hFlush stdout >> putStrLn (show $ property_leveled $ UnitLift t) 
    putStr (str++"  separating.............") >> hFlush stdout >> putStrLn (show $ property_separating $ UnitLift t)
    putStr (str++"  maxDescendentDistance..") >> hFlush stdout >> putStrLn (show $ property_maxDescendentDistance $ UnitLift t) 

    putStrLn ""
