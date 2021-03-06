{-# LANGUAGE Safe                 #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE OverloadedStrings    #-}
------------------------------------------------------------------------
-- |
-- Module      : AI.Rete.Flow
-- Copyright   : (c) 2015 Konrad Grzanek
-- License     : BSD-style (see the file LICENSE)
-- Created     : 2015-03-03
-- Maintainer  : kongra@gmail.com
-- Stability   : experimental
------------------------------------------------------------------------
module AI.Rete.Flow
    (
      -- * Adding Wmes
      addWme
    , addWmeP

      -- * Variables
      , Var
      , ToVar
      , var

      -- * Internals
    , genid
    , wmesIndexInsert
    , rightActivateJoin
    , ToConstantOrVariable (..)
    , fieldConstant
    )
    where

import           AI.Rete.Data
import           AI.Rete.State
import           Control.Monad (when, liftM3, forM)
import           Data.Foldable (toList)
import qualified Data.HashMap.Strict as Map
import qualified Data.HashSet as Set
import           Data.Hashable (Hashable)
import           Data.Int
import           Data.Maybe (isNothing)
import qualified Data.Text as T
import           Data.Word
import           Kask.Control.Lens (view, set, over)
import           Kask.Data.List (nthDef)

-- | Generates a new Id.
genid :: ReteM Id
genid = do
  state <- viewS Rete
  let recent = view reteId state
  when (recent == maxBound) (error "rete PANIC (2): Id OVERFLOW")

  let new = recent + 1
  setS Rete (set reteId new state)
  return new

-- INTERNING CONSTANTS AND VARIABLES

internConstant :: T.Text -> ReteM Constant
internConstant s = do
  cs <- fmap (view reteConstants) (viewS Rete)
  case Map.lookup s cs of
    Just c  -> return c
    Nothing -> do
      i    <- genid
      let c = TextConstant s i
      overS (over reteConstants (Map.insert s c)) Rete
      return c

internVariable :: T.Text -> ReteM Variable
internVariable s = do
  vs <- fmap (view reteVariables) (viewS Rete)
  case Map.lookup s vs of
    Just v  -> return v
    Nothing -> do
      i    <- genid
      let v = TextVariable s i
      overS (over reteVariables (Map.insert s v)) Rete
      return v

internFields :: (ToConstant o, ToConstant a, ToConstant v)
             => o -> a -> v
             -> ReteM (Obj Constant, Attr Constant, Val Constant)
internFields o a v =
  liftM3 (,,) (internField Obj o) (internField Attr a) (internField Val v)
{-# INLINE internFields #-}

internField :: ToConstant a => (Constant -> b) -> a -> ReteM b
internField f s = fmap f (toConstant s)
{-# INLINE internField #-}

-- WMES INDEXES MANIPULATION

type WmesIndexOperator a =
  (Hashable a, Eq a) => a -> Wme -> WmesIndex a -> WmesIndex a

-- | Creates an updated version of the wme index by putting a new
-- wme under the key k.
wmesIndexInsert ::  WmesIndexOperator a
wmesIndexInsert k wme index = Map.insert k (Set.insert wme s) index
  where s  = Map.lookupDefault Set.empty k index
{-# INLINE wmesIndexInsert #-}

addToWorkingMemory :: Wme -> ReteM ()
addToWorkingMemory wme@(Wme o a v) =
  overS
  (  over reteWmes       (Set.insert        wme)
   . over reteWmesByObj  (wmesIndexInsert o wme)
   . over reteWmesByAttr (wmesIndexInsert a wme)
   . over reteWmesByVal  (wmesIndexInsert v wme)) Rete

-- ALPHA MEMORY

activateAmem :: Amem -> Wme -> ReteM Agenda
activateAmem amem wme@(Wme o a v) = do
  state <- viewS amem
  setS amem $ (  over amemWmes       (wme:)
               . over amemWmesByObj  (wmesIndexInsert o wme)
               . over amemWmesByAttr (wmesIndexInsert a wme)
               . over amemWmesByVal  (wmesIndexInsert v wme)) state

  agendas <- mapM (rightActivateJoin wme) (view amemSuccessors state)
  return (concat agendas)

feedAmem :: Map.HashMap Wme Amem -> Wme -> Wme -> ReteM Agenda
feedAmem amems wme k = case Map.lookup k amems of
  Just amem -> activateAmem amem wme
  Nothing   -> return []
{-# INLINE feedAmem #-}

feedAmems :: Wme -> Obj Constant -> Attr Constant -> Val Constant -> ReteM Agenda
feedAmems wme o a v = do
  let w = wildcardConstant
  amems <- fmap (view reteAmems) (viewS Rete)

  a1 <- feedAmem amems wme $! Wme      o        a       v
  a2 <- feedAmem amems wme $! Wme      o        a  (Val w)
  a3 <- feedAmem amems wme $! Wme      o  (Attr w)      v
  a4 <- feedAmem amems wme $! Wme      o  (Attr w) (Val w)

  a5 <- feedAmem amems wme $! Wme (Obj w)       a       v
  a6 <- feedAmem amems wme $! Wme (Obj w)       a  (Val w)
  a7 <- feedAmem amems wme $! Wme (Obj w) (Attr w)      v
  a8 <- feedAmem amems wme $! Wme (Obj w) (Attr w) (Val w)

  return $ a1 ++ a2 ++ a3 ++ a4 ++ a5 ++ a6 ++ a7 ++ a8

-- BETA MEMORY

leftActivateBmem :: Bmem -> Tok -> Wme -> ReteM Agenda
leftActivateBmem bmem tok wme = do
  let newTok = wme:tok
  state <- viewS bmem
  setS bmem $ over bmemToks (newTok:) state

  agendas <- mapM (leftActivateJoin newTok) (view bmemChildren state)
  return (concat agendas)

-- UNINDEXED JOIN

performJoinTests :: [JoinTest] -> Tok -> Wme -> Bool
performJoinTests tests tok wme = all (passJoinTest tok wme) tests
{-# INLINE performJoinTests #-}

passJoinTest :: Tok -> Wme -> JoinTest -> Bool
passJoinTest tok wme
  JoinTest { joinField1 = f1, joinField2 = f2, joinDistance = d } =
    fieldConstant f1 wme == fieldConstant f2 wme2
    where
      wme2  = nthDef (error ("rete PANIC (3): ILLEGAL INDEX " ++ show d)) d tok

fieldConstant :: Field -> Wme -> Constant
fieldConstant O (Wme (Obj c)       _       _)  = c
fieldConstant A (Wme _       (Attr c)      _)  = c
fieldConstant V (Wme _             _  (Val c)) = c
{-# INLINE fieldConstant #-}

-- INDEXED JOIN

matchingAmemWmes :: [JoinTest] -> Tok -> AmemState -> [Wme]
matchingAmemWmes []    _   amemState = toList (view amemWmes amemState)
matchingAmemWmes tests tok amemState =  -- At least one test specified.
  toList (foldr Set.intersection s sets)
  where
    (s:sets) = map (amemWmesForTest tok amemState) tests
{-# INLINE matchingAmemWmes #-}

amemWmesForTest :: [Wme] -> AmemState -> JoinTest -> Set.HashSet Wme
amemWmesForTest wmes amemState
  JoinTest { joinField1 = f1, joinField2 = f2, joinDistance = d } =
    case f1 of
      O -> amemWmesForIndex (Obj  c) (view amemWmesByObj  amemState)
      A -> amemWmesForIndex (Attr c) (view amemWmesByAttr amemState)
      V -> amemWmesForIndex (Val  c) (view amemWmesByVal  amemState)
    where
      wme = nthDef (error ("rete PANIC (4): ILLEGAL INDEX " ++ show d)) d wmes
      c   = fieldConstant f2 wme

amemWmesForIndex :: (Hashable a, Eq a) => a -> WmesIndex a -> Set.HashSet Wme
amemWmesForIndex = Map.lookupDefault Set.empty
{-# INLINE amemWmesForIndex #-}

-- JOIN

rightActivateJoin :: Wme -> Join -> ReteM Agenda
rightActivateJoin wme join = do
  state   <- viewS join
  toks    <- fmap (view bmemToks) (viewS (joinParent join))
  agendas <- forM toks $ \tok ->
    if performJoinTests (joinTests join) tok wme
      then leftActivateJoinChildren state tok wme
      else return []

  return (concat agendas)

leftActivateJoin :: Tok -> Join -> ReteM Agenda
leftActivateJoin tok join = do
  state <- viewS join
  if noJoinChildren state
    then return []
    else do
      amemState <- viewS (joinAmem join)
      let wmes = matchingAmemWmes (joinTests join) tok amemState
      agendas <- forM wmes $ \wme -> leftActivateJoinChildren state tok wme
      return (concat agendas)

leftActivateJoinChildren :: JoinState -> Tok -> Wme -> ReteM Agenda
leftActivateJoinChildren state tok wme = do
  agenda <- case view joinChildBmem state of
    Just bmem -> leftActivateBmem bmem tok wme
    Nothing   -> return []

  agendas <- mapM (leftActivateProd tok wme) (view joinChildProds state)
  return (concat (agenda : agendas))

noJoinChildren :: JoinState -> Bool
noJoinChildren state =
  isNothing (view joinChildBmem state) && null (view joinChildProds state)
{-# INLINE noJoinChildren #-}

-- PROD

leftActivateProd :: Tok -> Wme -> Prod -> ReteM Agenda
leftActivateProd tok wme prod@Prod { prodPreds    = preds
                                   , prodAction   = action }  = do
  let newTok     = wme:tok
      actx       = Actx prod newTok
      matching p = p actx
      true       = id

  evaluatedPreds <- mapM matching preds
  if all true evaluatedPreds
    then return (map withThisProd (action actx))
    else return []

  where withThisProd task = task { taskProd = Just prod }

-- ADDING WMES

-- | Creates a task with default priority (0) that represents adding a Wme.
addWme :: (ToConstant o, ToConstant a, ToConstant v) => o -> a -> v -> Task
addWme o a v = addWmeP o a v 0

-- | Creates a task with given priority that represents adding a Wme.
addWmeP :: (ToConstant o, ToConstant a, ToConstant v)
        => o -> a -> v -> Int -> Task
addWmeP o a v priority = Task (addWmeA o a v) priority Nothing

-- | Creates the Agenda in Rete monad that represents adding a Wme.
addWmeA :: (ToConstant o, ToConstant a, ToConstant v) => o -> a -> v
        -> ReteM Agenda
addWmeA o a v = do
  (o', a', v') <- internFields o a v
  let wme = Wme o' a' v'
  state <- viewS Rete
  if Set.member wme (view reteWmes state)
    then return [] -- Already present, do nothing.
    else do
      addToWorkingMemory wme
      feedAmems wme o' a' v'

-- INTERNING PRIMITIVES

-- | Represents a constant at the system level.
class ToConstant a where
  -- | Interns and returns a Symbol for the name argument.
  toConstant :: a -> ReteM Constant

instance ToConstant Constant where
  -- We may simply return the argument here, because Constants once
  -- interned never expire (get un-interned).
  toConstant = return
  {-# INLINE toConstant #-}

instance ToConstant (ReteM Constant) where
  toConstant = id
  {-# INLINE toConstant #-}

instance ToConstant Primitive where
  -- Every Primitive is treated as a Const.
  toConstant = return . PrimitiveConstant
  {-# INLINE toConstant #-}

instance ToConstant Bool where
  toConstant = toConstant . BoolPrimitive
  {-# INLINE toConstant #-}

instance ToConstant Char where
  toConstant = toConstant . CharPrimitive
  {-# INLINE toConstant #-}

instance ToConstant Double where
  toConstant = toConstant . DoublePrimitive
  {-# INLINE toConstant #-}

instance ToConstant Float where
  toConstant = toConstant . FloatPrimitive
  {-# INLINE toConstant #-}

instance ToConstant Int where
  toConstant = toConstant . IntPrimitive
  {-# INLINE toConstant #-}

instance ToConstant Int8 where
  toConstant = toConstant . Int8Primitive
  {-# INLINE toConstant #-}

instance ToConstant Int16 where
  toConstant = toConstant . Int16Primitive
  {-# INLINE toConstant #-}

instance ToConstant Int32 where
  toConstant = toConstant . Int32Primitive
  {-# INLINE toConstant #-}

instance ToConstant Int64 where
  toConstant = toConstant . Int64Primitive
  {-# INLINE toConstant #-}

instance ToConstant Integer where
  toConstant = toConstant . IntegerPrimitive
  {-# INLINE toConstant #-}

instance ToConstant Word where
  toConstant = toConstant . WordPrimitive
  {-# INLINE toConstant #-}

instance ToConstant Word8 where
  toConstant = toConstant . Word8Primitive
  {-# INLINE toConstant #-}

instance ToConstant Word16 where
  toConstant = toConstant . Word16Primitive
  {-# INLINE toConstant #-}

instance ToConstant Word32 where
  toConstant = toConstant . Word32Primitive
  {-# INLINE toConstant #-}

instance ToConstant Word64  where
  toConstant = toConstant . Word64Primitive
  {-# INLINE toConstant #-}

instance ToConstant T.Text where
  -- Raw String is always a constant.
  toConstant name
    | T.null name = return emptyConstant
    | otherwise   = internConstant name
  {-# INLINE toConstant #-}

instance ToConstant String where
  toConstant = toConstant . T.pack
  {-# INLINE toConstant #-}

instance ToConstant NamedPrimitive where
  toConstant = return . NamedPrimitiveConstant
  {-# INLINE toConstant #-}

-- EXPLICIT CONSTRUCTORS FOR VARIABLES

type Var = ReteM Variable

-- | A type of values with a variable semantics.
class ToVar a where
  -- | Marks a thing as a variable resulting in a Symbolic value.
  var :: a -> Var

instance ToVar T.Text where
  var s
    | T.null s  = error "rete ERROR (1): EMPTY VARIABLE NAME"
    | otherwise = internVariable s

instance ToVar String where var = var . T.pack

instance ToVar NamedPrimitive where
  var np@(NamedPrimitive _ name)
    | T.null name = error "rete ERROR (2): EMPTY VARIABLE NAME"
    | otherwise   = return (NamedPrimitiveVariable np)

instance ToVar Var where
  var = id
  {-# INLINE var #-}

class ToConstantOrVariable a where
  toConstantOrVariable :: a -> ReteM ConstantOrVariable

instance ToConstantOrVariable ConstantOrVariable where
  toConstantOrVariable = return
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Var where
  toConstantOrVariable = fmap JustVariable
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Primitive where
  -- Every Primitive is treated as a Const.
  toConstantOrVariable = return . JustConstant . PrimitiveConstant
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Bool where
  toConstantOrVariable = toConstantOrVariable . BoolPrimitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Char where
  toConstantOrVariable = toConstantOrVariable . CharPrimitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Double where
  toConstantOrVariable = toConstantOrVariable . DoublePrimitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Float where
  toConstantOrVariable = toConstantOrVariable . FloatPrimitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Int where
  toConstantOrVariable = toConstantOrVariable . IntPrimitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Int8 where
  toConstantOrVariable = toConstantOrVariable . Int8Primitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Int16 where
  toConstantOrVariable = toConstantOrVariable . Int16Primitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Int32 where
  toConstantOrVariable = toConstantOrVariable . Int32Primitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Int64 where
  toConstantOrVariable = toConstantOrVariable . Int64Primitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Integer where
  toConstantOrVariable = toConstantOrVariable . IntegerPrimitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Word where
  toConstantOrVariable = toConstantOrVariable . WordPrimitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Word8 where
  toConstantOrVariable = toConstantOrVariable . Word8Primitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Word16 where
  toConstantOrVariable = toConstantOrVariable . Word16Primitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Word32 where
  toConstantOrVariable = toConstantOrVariable . Word32Primitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable Word64  where
  toConstantOrVariable = toConstantOrVariable . Word64Primitive
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable T.Text where
  -- Raw String is always a constant.
  toConstantOrVariable s
    | T.null s  = return (JustConstant emptyConstant)
    | otherwise = fmap JustConstant (internConstant s)
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable String where
  toConstantOrVariable = toConstantOrVariable . T.pack
  {-# INLINE toConstantOrVariable #-}

instance ToConstantOrVariable NamedPrimitive where
  toConstantOrVariable = return . JustConstant . NamedPrimitiveConstant
  {-# INLINE toConstantOrVariable #-}
