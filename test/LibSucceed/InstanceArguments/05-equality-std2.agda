{-# OPTIONS --universe-polymorphism #-}
-- {-# OPTIONS --verbose tc.rec:15 #-}
-- {-# OPTIONS --verbose tc.records.ifs:15 #-}
-- {-# OPTIONS --verbose tc.constr.findInScope:15 #-}
-- {-# OPTIONS --verbose tc.term.args.ifs:15 #-}

module InstanceArguments.05-equality-std2 where

open import Agda.Primitive
open import Relation.Nullary
open import Relation.Binary
open import Relation.Binary.PropositionalEquality
open import Data.Bool hiding (_≟_)

open DecSetoid {{...}}

instance
  decBool = Data.Bool.decSetoid

test : IsDecEquivalence (_≡_ {A = Bool})
test = isDecEquivalence

test2 = false ≟ false
