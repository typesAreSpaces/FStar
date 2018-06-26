module Typeclasses

open FStar.Tactics
module T = FStar.Tactics
open FStar.Tactics.Typeclasses

(* An experiment on typeclasses using metaprogrammed arguments. *)

(*
 * The heavy lifting is done via the (dead simple) tcresolve metaprogram
 * which just tries to apply everything marked with the `instance` attribute
 * recursively in order to solve a goal. `Classes` have no meaning, they
 * can be any type.
 *
 * We do want some *sugar* for classes and instances, but the basic idea is here *)

(* A class for decidable equality *)
noeq
type deq a = {
  eq    : a -> a -> bool;
  eq_ok : (x:a) -> (y:a) -> Lemma (__fname__eq x y <==> x == y) // hacking a dependent record
}

%splice[eq;eq_ok] (mk_class (`%deq))

(* These methods are generated by the splice *)
(* [@tcnorm] let eq_ok (#a:Type) [|d : deq a|] = d.eq_ok *)
(* [@tcnorm] let eq    (#a:Type) [|d : deq a|] = d.eq *)

(* A way to get `deq a` for any `a : eqtype` *)
let eq_instance_of_eqtype (#a:eqtype) : deq a =
  Mkdeq (fun x y -> x = y) (fun x y -> ())

(* Two concrete instances *)
[@instance] let eq_int : deq int  = eq_instance_of_eqtype
[@instance] let eq_bool : deq bool  = eq_instance_of_eqtype

(* A parametric instance *)
[@instance] let eq_list (eqA : deq 'a) : deq (list 'a) =
  let rec eqList (xs ys : list 'a) : Tot (b:bool{b <==> xs == ys}) = match xs, ys with
  | [], [] -> true
  | x::xs, y::ys -> eq_ok x y; eq x y && eqList xs ys
  | _, _ -> false
  in
  Mkdeq eqList (fun x y -> ())

(* A few tests *)
let _ = assert (eq 1 1)
let _ = assert (not (eq 1 2))

let _ = assert (eq true true)
let _ = assert (not (eq true false))

// Need the assert_norm...
let _ = assert_norm (eq [1;2] [1;2])
let _ = assert_norm (not (eq [2;1] [1;2]))


(****************************************************************)

(* A class for additive monoids *)
noeq
type additive a = {
  zero       : a;
  plus       : a -> a -> a;
  zero_l     : ((x : a) -> Lemma (__fname__plus __fname__zero x == x));
  zero_r     : ((x : a) -> Lemma (__fname__plus x __fname__zero == x));
  plus_assoc : ((x : a) -> (y : a) -> (z : a)
                  -> Lemma (__fname__plus (__fname__plus x y) z == __fname__plus x (__fname__plus y z)));
}

(*
 * A smart constructor, would be nice to autogen too.
 * But how? Mark some methods as `irrel`?
 * Note there's a nontrivial translation. Should we do forall's? Lemmas? Squashes?
 *)
val mkadd : #a:Type -> zero:a -> plus:(a -> a -> a)
             -> Pure (additive a)
                    (requires  (forall (x : a). plus zero x == x)
                            /\ (forall (x : a). plus x zero == x)
                            /\ (forall (x y z : a).plus (plus x y) z == plus x (plus y z)))
                    (ensures (fun d -> Mkadditive?.zero d == zero /\ Mkadditive?.plus d == plus))
let mkadd #a zero plus = Mkadditive zero plus (fun x -> ()) (fun x -> ()) (fun x y z -> ())

%splice [zero;plus;zero_l;zero_r;plus_assoc] (mk_class (`%additive))

(* These methods are generated by the splice *)
(* [@tcnorm] let zero       (#a:Type) [|d : additive a|] = d.zero *)
(* [@tcnorm] let plus       (#a:Type) [|d : additive a|] = d.plus *)
(* [@tcnorm] let zero_l     (#a:Type) [|d : additive a|] = d.zero_l *)
(* [@tcnorm] let zero_r     (#a:Type) [|d : additive a|] = d.zero_r *)
(* [@tcnorm] let plus_assoc (#a:Type) [|d : additive a|] = d.plus_assoc *)

(* Instances *)
[@instance]
let add_int : additive int = mkadd 0 (+)

[@instance]
let add_bool : additive bool =
  mkadd false ( || )

[@instance]
let add_list #a : additive (list a) =
  (* Couldn't use the smart mkadd here, oh well *)
  let open FStar.List.Tot in
  Mkadditive [] (@) append_nil_l append_l_nil append_assoc

(* Tests *)
let _ = assert (plus 1 2 = 3)
let _ = assert (plus false false = false)
let _ = assert (plus true false = true)
let _ = assert (plus [1] [2] = [1;2])


(****************************************************************)

(* Numeric class, including superclasses for decidable equality
 * and a monoid, extended with a minus operation. *)
noeq
type num a = {
    eq_super : deq a;
    add_super : additive a;
    minus : a -> a -> a;
}
%splice[minus] (mk_class (`%num))

(* These methods are generated by the splice *)
(* [@tcnorm] let minus (#a:Type) [|d : num a|] = d.minus *)

(* Superclass projectors! Should also be autogenerated. Note the `instance` attribute,
 * differently from the methods, since these participate in the search. *)
[@instance] let num_eq  (d : num 'a) : deq 'a = d.eq_super
[@instance] let add_num (d : num 'a) : additive 'a = d.add_super

(* Note the `solve` in the superclass, meaning we don't have to give it explicitly.
 * Anyway, we should remove the need to even write that line. *)
[@instance]
let num_int : num int =
  { eq_super  = solve;
    add_super = solve;
    minus     = (fun x y -> x - y); }

[@instance]
let num_bool : num bool =
  { eq_super  = solve;
    add_super = solve;
    minus     = (fun x y -> x && not y) (* random crap *); }

(****************************************************************)

(* Up to now, that was actually just simple overloading. Let's try some
 * polymorphic uses *)

let rec sum (#a:Type) [|additive a|] (l : list a) : a =
    match l with
    | [] -> zero
    | x::xs -> plus x (sum xs)

let sum2 (#a:Type) [|additive a|] (l : list a) : a =
    List.Tot.fold_right plus l zero

let _ = assert_norm (sum2 [1;2;3;4] == 10)
let _ = assert_norm (sum2 [false; true] == true)

let sandwich (#a:Type) [|num a|] (x y z : a) : a =
    if eq x y
    then plus x z
    else minus y z

let test1 = assert (sum [1;2;3;4;5;6] == 21)
let test2 = assert (plus 40 (minus 10 8) == 42)
