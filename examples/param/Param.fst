module Param
open FStar.List.Tot
open FStar.Tactics

type bvmap = list (bv & (binder & binder & binder))

let update_bvmap (bv:bv) (b0 b1 b2 : binder) (bvm : bvmap) : bvmap =
  (bv, (b0, b1, b2)) :: bvm

let rec lookup (bvm : bvmap) (bv:bv) : Tac (binder & binder & binder) =
  match bvm with
  | [] ->
    fail ("not found: " ^ bv_to_string bv)
  | (bv', r)::tl ->
    if compare_bv bv bv' = Order.Eq
    then r
    else lookup tl bv

let replace_var (bvmap:bvmap) (b:bool) (t:term) : Tac term =
  match inspect_ln t with
  | Tv_Var bv ->
    let (x, y, _) = lookup bvmap bv in
    let bv = if b then fst (inspect_binder y) else fst (inspect_binder x) in
    pack (Tv_Var bv)
  | _ -> t

let replace_by (bvmap:bvmap) (b:bool) (t:term) : Tac term =
  let r = visit_tm (replace_var bvmap b) t in
  //print ("rep " ^ string_of_bool b ^ " " ^ term_to_string t ^ " = " ^ term_to_string r);
  r

let rec list_rec #t1 #t2 (r : t1 -> t2 -> Type) (l1 : list t1) (l2 : list t2) =
  match l1, l2 with
  | [], [] -> True
  | h1::t1, h2::t2 -> r h1 h2 /\ list_rec r t1 t2
  | _ -> False

let param_list = (fun (t1 t2 : Type) rel_f l1 l2 -> squash (list_rec #t1 #t2 rel_f l1 l2))
let param_int = (fun (x y : int) -> squash (x == y))

let binder_set_qual (b:binder) (q:aqualv) : Tac binder =
  let bv, (_, attrs) = inspect_binder b in
  pack_binder bv q attrs

let rec param' (bvmap : bvmap) (t:term) : Tac term =
  let r =
  match inspect t with
  | Tv_Type () ->
    `(fun (s t : Type) -> s -> t -> Type0)
  | Tv_Var bv ->
    let (_, _, b) = lookup bvmap bv in
    binder_to_term b
  | Tv_Arrow b c ->
    let bv, (q, _attrs) = inspect_binder b in
    begin match inspect_comp c with
    | C_Total t2 _ ->
      let t1 = (inspect_bv bv).bv_sort in
      // bv:t1 -> t2

      let app q t1 t2 = pack (Tv_App t1 (t2, q)) in
      let abs b t : Tac term = pack (Tv_Abs b t) in
      let bf0 = fresh_binder_named "f0" (replace_by bvmap false t) in
      let bf1 = fresh_binder_named "f1" (replace_by bvmap true t) in
      let bx0 = fresh_binder_named "x0" (replace_by bvmap false t1) in
      let bx1 = fresh_binder_named "x1" (replace_by bvmap true t1) in
      let brx = fresh_binder_named "xR" (`(`#(param' bvmap t1)) (`#bx0) (`#bx1)) in
      let bvmap' = update_bvmap bv bx0 bx1 brx bvmap in
      let res = `((`#(param' bvmap' t2)) (`#(app q bf0 bx0)) (`#(app q bf1 bx1))) in
      abs bf0 (abs bf1 (mk_tot_arr [bx0; bx1; brx] res))
    | _ -> fail "we don't support effects"
    end

  | Tv_App l (r, q) ->
    let lR = param' bvmap l in
    let l0 = replace_by bvmap false r in
    let l1 = replace_by bvmap true r in
    let rR = param' bvmap r in
    mk_e_app lR [l0; l1; rR]

 | Tv_Abs b t ->
    let abs b t : Tac term = pack (Tv_Abs b t) in
    let (bv, q) = inspect_binder b in
    let bvs = (inspect_bv bv).bv_sort in
    let bx0 = fresh_binder_named "z0" (replace_by bvmap false bvs) in
    let bx1 = fresh_binder_named "z1" (replace_by bvmap true bvs) in
    let bxR = fresh_binder_named "zR" (`(`#(param' bvmap bvs)) (`#bx0) (`#bx1)) in
    let bvmap' = update_bvmap bv bx0 bx1 bxR bvmap in
    let t = param' bvmap' t in
    abs bx0 (abs bx1 (abs bxR t))

  | Tv_FVar fv ->
    if fv_to_string fv = "Prims.list" then
      `param_list
    else if fv_to_string fv = "Prims.int" then
      `param_int
    else
    fail ("unknown fv: " ^ fv_to_string fv)

  | _ ->
    let q = inspect t in
    fail ("unexpec " ^ term_to_string (quote q))
  in
  r

let param t =
  let t = param' [] t in
  let t = norm_term [] t in
  //dump ("res = " ^ term_to_string t);
  t

[@@(preprocess_with param)]
let test0 = Type

[@@(preprocess_with param)]
let test1 = Type -> Type

[@@(preprocess_with param)]
let test2 = bd1:Type -> bd2:Type -> bd1

// GM: Using implicits here. The `param` metaprogram is meant to handle
// them properly but take that with a grain of salt.
[@@(preprocess_with param)]
let param_id = #a:Type -> a -> a

let id (#a:Type0) (x:a) : a = x

let id_is_unique (f : (#a:Type -> a -> a)) (f_parametric : param_id f f) : Lemma (forall a (x:a). f x == x) =
  let aux a x : Lemma (f x == x) =
    f_parametric a unit (fun y () -> squash (x == y)) x () ()
  in
  Classical.forall_intro_2 aux

[@@preprocess_with param]
let id_is_param = (fun (#a:Type) (x:a) -> x)

let test () = id_is_unique id id_is_param

[@@preprocess_with param]
let binop_param = #a:Type -> a -> a -> a

let binop_is_fst_or_snd_pointwise (f : (#a:Type -> a -> a -> a)) (f_param : binop_param f f)
  : Lemma (forall a (x y : a). f x y == x \/ f x y == y)
  =
  let aux a (x y : a) : Lemma (f x y == x \/ f x y == y) =
   f_param a unit (fun z () -> squash (z == x \/ z == y)) x () () y () ()
  in
  Classical.forall_intro_3 aux

let binop_is_fst_or_snd_extensional (f : (#a:Type -> a -> a -> a)) (f_param : binop_param f f)
  : Lemma ((forall a (x y : a). f x y == x) \/ (forall a (x y : a). f x y == y))
  =
  binop_is_fst_or_snd_pointwise f f_param;
  assert (f 1 2 == 1 \/ f 1 2 == 2);
  let aux1 (_ : squash (f 1 2 == 1))
           a (x y : a) : Lemma (f x y == x) =
   f_param a int (fun z i -> squash (i == 1 ==> z == x)) x 1 () y 2 ()
  in
  let aux2 (_ : squash (f 1 2 == 2))
           a (x y : a) : Lemma (f x y == y) =
   f_param a int (fun z i -> squash (i == 2 ==> z == y)) x 1 () y 2 ()
  in
  let aux1' () : Lemma (requires (f 1 2 == 1)) (ensures (forall a (x y : a). f x y == x)) =
    Classical.forall_intro_3 (aux1 ())
  in
  let aux2' () : Lemma (requires (f 1 2 == 2)) (ensures (forall a (x y : a). f x y == y)) =
    Classical.forall_intro_3 (aux2 ())
  in
  Classical.move_requires aux1' ();
  Classical.move_requires aux2' ()

[@@(preprocess_with param)]
let test_int_to_int = int -> int

[@@(preprocess_with param)]
let test_list_0 = list

[@@(preprocess_with param)]
let test_list = list int

[@@(preprocess_with param)]
let rev_param = a:Type -> list a -> list a

let rel_of_fun #a #b (f : a -> b) : a -> b -> Type =
  fun x y -> y == f x

let rec list_rec_of_function_is_map #a #b (f : a -> b) (l1 : list a) (l2 : list b)
        : Lemma (list_rec (rel_of_fun f) l1 l2 <==> l2 == List.Tot.map f l1)
 = match l1, l2 with
   | [], [] -> ()
   | h1::t1, h2::t2 -> list_rec_of_function_is_map f t1 t2
   | _ -> ()

let reverse_commutes_with_map
    (rev : (a:Type -> list a -> list a)) // doesn't really have to be "reverse"...
    (rev_is_param : rev_param rev rev)
    : Lemma (forall a b (f : a -> b) l. rev b (List.Tot.map f l) == List.Tot.map f (rev a l))
    =
  let aux a b f l : Lemma (rev b (List.Tot.map f l) == List.Tot.map f (rev a l)) =
    let rel_f : a -> b -> Type = rel_of_fun f in
    list_rec_of_function_is_map f l (List.Tot.map f l);
    rev_is_param a b rel_f l (List.Tot.map f l) ();
    list_rec_of_function_is_map f (rev _ l) (rev _ (List.Tot.map f l));
    ()
  in
  Classical.forall_intro_4 aux

let rec reverse (a:Type) (l : list a) : list a =
  match l with
  | [] -> []
  | x::xs -> reverse _ xs @ [x]

let rec lem_rel_app (a0 a1 : Type) (ra : a0 -> a1 -> Type)
                (l0 r0 : list a0) (l1 r1 : list a1)
                : Lemma (requires (list_rec ra l0 l1 /\ list_rec ra r0 r1))
                        (ensures (list_rec ra (l0@r0) (l1@r1))) =
   match l0, l1 with                       
   | h0::t0, h1::t1 -> lem_rel_app a0 a1 ra t0 r0 t1 r1
   | _ -> ()

(* Doesn't work by SMT, and tactic above does not handle fixpoints.
 * What to do about them? Is there a translation for general recursion?
 * Should read https://openaccess.city.ac.uk/id/eprint/1072/1/PFF.pdf in
 * more detail. *)
let rev_is_param () : rev_param reverse reverse =
  fun a0 a1 ra l0 l1 (sq : squash (list_rec ra l0 l1)) ->
    let rec aux l0 l1 : Lemma (requires (list_rec ra l0 l1))
                          (ensures list_rec ra (reverse _ l0) (reverse _ l1)) =
      match l0, l1 with
      | h0::t0, h1::t1 -> aux t0 t1; lem_rel_app _ _ ra (reverse _ t0) [h0] (reverse _ t1) [h1]
      | _ -> ()
    in
    aux l0 l1

let real_reverse_commutes_with_map ()
  : Lemma (forall a b (f : a -> b) l. reverse b (List.Tot.map f l) == List.Tot.map f (reverse a l))
  = reverse_commutes_with_map reverse (rev_is_param ())
