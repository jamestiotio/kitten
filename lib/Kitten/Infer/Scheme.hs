{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PostfixOperators #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Kitten.Infer.Scheme
  ( Occurrences(..)
  , Simplify(..)
  , Substitute(..)
  , free
  , generalize
  , instantiate
  , instantiateM
  , normalize
  , occurs
  ) where

import Control.Monad.Trans.State.Strict
import Data.Foldable (foldrM)
import Data.List
import Data.Monoid
import Data.Set (Set)

import qualified Data.Set as S

import Kitten.Infer.Monad
import Kitten.Location
import Kitten.Name
import Kitten.Type
import Kitten.Util.Monad

import qualified Kitten.NameMap as N

instantiateM :: Scheme -> Inferred (Type Scalar)
instantiateM scheme = do
  loc <- getsEnv envLocation
  liftState $ state (instantiate loc scheme)

instantiate :: Location -> Scheme -> Env -> (Type Scalar, Env)
instantiate loc (Forall rows scalars effects type_) env
  = (sub renamed type_, env')

  where
  renamed :: Env
  env' :: Env
  (renamed, env') = flip runState env $ composeM
    [ renames rows
    , renames scalars
    , renames effects
    ] emptyEnv

  renames
    :: (Declare a)
    => Set (TypeName a)
    -> Env
    -> State Env Env
  renames = flip (foldrM rename) . S.toList

  rename
    :: (Declare a)
    => TypeName a
    -> Env
    -> State Env Env
  rename name localEnv = do
    var <- state (freshVar loc)
    return (declare name var localEnv)

generalize :: Inferred (Type Scalar) -> Inferred Scheme
generalize action = do
  type_ <- action
  after <- getEnv

  let
    substituted :: Type Scalar
    substituted = sub after type_

    rows :: [TypeName Row]
    scalars :: [TypeName Scalar]
    effects :: [TypeName Effect]
    (rows, scalars, effects) = freeVars substituted

  return $ Forall
    (S.fromList rows)
    (S.fromList scalars)
    (S.fromList effects)
    substituted

freeVars
  :: (Free a)
  => Type a
  -> ([TypeName Row], [TypeName Scalar], [TypeName Effect])
freeVars type_
  = let (rows, scalars, effects) = free type_
  in (nub rows, nub scalars, nub effects)

class Free a where
  free
    :: Type a
    -> ([TypeName Row], [TypeName Scalar], [TypeName Effect])

instance Free Effect where
  free type_ = case type_ of
    a :+ b -> free a <> free b
    Test -> mempty
    NoEffect _ -> mempty
    IOEffect _ -> mempty
    Var name _ -> ([], [], [effect name])

instance Free Row where
  free type_ = case type_ of
    a :. b -> free a <> free b
    Empty{} -> mempty
    Test{} -> mempty
    Var name _ -> ([row name], [], [])

instance Free Scalar where
  free type_ = case type_ of
    a :& b -> free a <> free b
    (:?) a -> free a
    a :| b -> free a <> free b
    Function a b _ _ -> free a <> free b
    Bool{} -> mempty
    Char{} -> mempty
    Float{} -> mempty
    Handle{} -> mempty
    Int{} -> mempty
    Named{} -> mempty
    Test{} -> mempty
    Var name _ -> ([], [scalar name], [])
    Unit{} -> mempty
    Vector a _ -> free a

normalize :: Location -> Type Scalar -> Type Scalar
normalize loc type_ = let
  (rows, scalars, effects) = freeVars type_
  rowCount = length rows
  rowScalarCount = rowCount + length scalars
  env = emptyEnv
    { envRows = N.fromList
      $ zip (map typeName rows) (map var [0..])
    , envScalars = N.fromList
      $ zip (map typeName scalars) (map var [rowCount..])
    , envEffects = N.fromList
      $ zip (map typeName effects) (map var [rowScalarCount..])
    }
  in sub env type_
  where
  var :: Int -> Type a
  var index = Var (Name index) loc

occurs :: (Occurrences a) => Name -> Env -> Type a -> Bool
occurs = (((> 0) .) .) . occurrences

class Occurrences a where
  occurrences :: Name -> Env -> Type a -> Int

instance Occurrences Effect where
  occurrences name env type_ = case type_ of
    a :+ b -> occurrences name env a + occurrences name env b
    NoEffect _ -> 0
    IOEffect _ -> 0
    Test -> 0
    Var name' _ -> case retrieve env (effect name') of
      Left{} -> if name == name' then 1 else 0
      Right type' -> occurrences name env type'

instance Occurrences Row where
  occurrences name env type_ = case type_ of
    a :. b -> occurrences name env a + occurrences name env b
    Empty{} -> 0
    Test -> 0
    Var name' _ -> case retrieve env (row name') of
      Left{} -> if name == name' then 1 else 0
      Right type' -> occurrences name env type'

instance Occurrences Scalar where
  occurrences name env type_ = case type_ of
    a :& b -> occurrences name env a + occurrences name env b
    (:?) a -> occurrences name env a
    a :| b -> occurrences name env a + occurrences name env b
    Function a b _ _
      -> occurrences name env a
      + occurrences name env b
    Bool{} -> 0
    Char{} -> 0
    Float{} -> 0
    Handle{} -> 0
    Int{} -> 0
    Named{} -> 0
    Test{} -> 0
    Var name' _ -> case retrieve env (scalar name') of
      Left{} -> if name == name' then 1 else 0
      Right type' -> occurrences name env type'
    Unit{} -> 0
    Vector a _ -> occurrences name env a

class Simplify a where
  simplify :: Env -> Type a -> Type a

instance Simplify Effect where
  simplify env type_ = case type_ of
    Var name _
      | Right type' <- retrieve env (effect name)
      -> simplify env type'
    _ -> type_

instance Simplify Row where
  simplify env type_ = case type_ of
    Var name _
      | Right type' <- retrieve env (row name)
      -> simplify env type'
    _ -> type_

instance Simplify Scalar where
  simplify env type_ = case type_ of
    Var name _
      | Right type' <- retrieve env (scalar name)
      -> simplify env type'
    _ -> type_

class Substitute a where
  sub :: Env -> Type a -> Type a

instance Substitute Effect where
  sub env type_ = case type_ of
    a :+ b -> sub env a +: sub env b
    NoEffect _ -> type_
    IOEffect _ -> type_
    Test{} -> type_
    Var name _
      | Right type' <- retrieve env (effect name)
      -> sub env type'
      | otherwise
      -> type_

instance Substitute Row where
  sub env type_ = case type_ of
    a :. b -> sub env a :. sub env b
    Empty{} -> type_
    Test{} -> type_
    Var name _
      | Right type' <- retrieve env (row name)
      -> sub env type'
      | otherwise
      -> type_

instance Substitute Scalar where
  sub env type_ = case type_ of
    Function a b e loc -> Function
      (sub env a)
      (sub env b)
      (sub env e)
      loc
    a :& b -> sub env a :& sub env b
    (:?) a -> (sub env a :?)
    a :| b -> sub env a :| sub env b
    Bool{} -> type_
    Char{} -> type_
    Float{} -> type_
    Int{} -> type_
    Handle{} -> type_
    Named{} -> type_
    Test -> type_
    Var name _
      | Right type' <- retrieve env (scalar name)
      -> sub env type'
      | otherwise
      -> type_
    Unit{} -> type_
    Vector a loc -> Vector (sub env a) loc
