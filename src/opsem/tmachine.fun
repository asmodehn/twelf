(* Abstract Machine for Tracing *)
(* Author: Frank Pfenning *)

functor TMachine (structure IntSyn' : INTSYN
		  structure CompSyn' : COMPSYN
		    sharing CompSyn'.IntSyn = IntSyn'
		  structure Unify : UNIFY
		    sharing Unify.IntSyn = IntSyn'
		  structure Index : INDEX
		    sharing Index.IntSyn = IntSyn'
		  structure Trail : TRAIL
		    sharing Trail.IntSyn = IntSyn'
                  structure CPrint : CPRINT 
                    sharing CPrint.IntSyn = IntSyn'
                    sharing CPrint.CompSyn = CompSyn'
		  structure Names : NAMES
		    sharing Names.IntSyn = IntSyn'
		  structure Trace : TRACE
		    sharing Trace.IntSyn = IntSyn')
  : ABSMACHINE =
struct

  structure IntSyn = IntSyn'
  structure CompSyn = CompSyn'

  local
    structure I = IntSyn
    structure T = Trace
    structure N = Names
    open CompSyn
  in

    fun subgoalNum (I.Nil) = 1
      | subgoalNum (I.App (U, S)) = 1 + subgoalNum S

  (* We write
       G |- M : g
     if M is a canonical proof term for goal g which could be found
     following the operational semantics.  In general, the
     success continuation sc may be applied to such M's in the order
     they are found.  Backtracking is modeled by the return of
     the success continuation.

     Similarly, we write
       G |- S : r
     if S is a canonical proof spine for residual goal r which could
     be found following the operational semantics.  A success continuation
     sc may be applies to such S's in the order they are found and
     return to indicate backtracking.
  *)

  (* solve ((g, s), dProg, sc) => ()
     Invariants:
       dProg = (G, dPool) where  G ~ dPool  (context G matches dPool)
       G |- s : G'
       G' |- g  goal
       if  G |- M : g[s]
       then  sc M  is evaluated
     Effects: instantiation of EVars in g, s, and dProg
              any effect  sc M  might have
  *)
  fun solve ((Atom(p), s), dProg as (G, dPool), sc) =
      ((* traceMsg (fn () => "Solving atomic goal\n");
       traceInfo (fn () => P.expToString (G, I.EClo(p,s))); *)
       matchAtom ((p,s), dProg, sc))
    | solve ((Impl(r, A, a, g), s), (G, dPool), sc) =
      let
	val D' as I.Dec(SOME(x),_) = N.decName (G, I.Dec(NONE, I.EClo(A,s)))
	val _ = T.signal (T.IntroHyp (fn () => (G, D')))
      in
	solve ((g, I.dot1 s), (I.Decl(G, D'), I.Decl (dPool, SOME(r, s, a))),
	       (fn M => (T.signal (T.DischargeHyp (fn () => (G, D')));
			 sc (I.Lam (D', M)))))
      end
    | solve ((All(D, g), s), (G, dPool), sc) =
      let
	val D' as I.Dec(SOME(x),_) = N.decName (G, I.decSub (D, s))
	val _ = T.signal (T.IntroParm (fn () => (G, D')))
      in
	solve ((g, I.dot1 s), (I.Decl(G, D'), I.Decl(dPool, NONE)),
	       (fn M => (T.signal (T.DischargeParm (fn () => (G, D')));
			 sc (I.Lam (D', M)))))
      end

  (* rsolve ((p,s'), (r,s), dProg, H, sc) = ()
     Invariants: 
       dProg = (G, dPool) where G ~ dPool
       G |- s : G'
       G' |- r  resgoal
       G |- s' : G''
       G'' |- p : H @ S' (mod whnf)
       if G |- S : r[s]
       then sc S is evaluated
       H is the clause which generated this residual goal
     Effects: instantiation of EVars in p[s'], r[s], and dProg
              any effect  sc S  might have
  *)
  and rSolve (ps', (Eq(Q), s), (G, dPool), H, sc) =
     ((* traceMsg (fn () => "Trying clause ");
      traceInfo (fn () => H);
      traceMsg (fn () => "Unifying\n");
      traceInfo (fn () => P.expToString (G, I.EClo ps') ^ " == "
		 ^ P.expToString (G, I.EClo (Q, s))); *)
      if Unify.unifiable (G, ps', (Q, s)) (* effect: instantiate EVars *)
	then (T.signal (T.Resolved (G, H));
	      sc I.Nil;			(* call success continuation *)
	      true)			(* deep backtracking *)
      else ((* traceMsg (fn () => "Failed\n"); *)
	    false)			(* shallow backtracking *)
      )
    | rSolve (ps', (And(r, A, g), s), dProg as (G, dPool), H, sc) =
      let
	(* is this EVar redundant? -fp *)
	val X = I.newEVar (G, I.EClo(A, s))
      in
        rSolve (ps', (r, I.Dot(I.Exp(X), s)), dProg, H,
		(fn S => 
		 (T.signal (T.Subgoal (G, H, fn () => subgoalNum S));
		  solve ((g, s), dProg,
			 (fn M => 
			  (sc (I.App (M, S))))))))
      end
    | rSolve (ps', (Exists(I.Dec(_,A), r), s), dProg as (G, dPool), H, sc) =
      let
	val X = I.newEVar (G, I.EClo (A,s))
	(* val _ = traceMsg (fn () => "Introducing new EVar ")*)
	(* val _ = traceInfo (fn () => N.evarName (G, X)
			   ^ " : " ^ P.expToString (G, I.EClo (A, s))) *)
      in
	rSolve (ps', (r, I.Dot(I.Exp(X), s)), dProg, H,
		(fn S => sc (I.App(X,S))))
      end

  (* matchatom ((p, s), dProg, sc) => ()
     Invariants:
       dProg = (G, dPool) where G ~ dPool
       G |- s : G'
       G' |- p : type, p = H @ S mod whnf
       if G |- M :: p[s]
       then sc M is evaluated
     Effects: instantiation of EVars in p[s] and dProg
              any effect  sc M  might have

     This first tries the local assumptions in dProg then
     the static signature.
  *)
  and matchAtom (ps' as (I.Root(H as I.Const(a),_),_), dProg as (G,dPool), sc) =
      let
        (* matchSig [c1,...,cn] = ()
	   try each constant ci in turn for solving atomic goal ps', starting
           with c1.
        *)
	val tag = T.tagGoal ()
	val _ = T.signal (T.SolveGoal (tag, H, (fn () => (G, I.EClo ps'))))
	fun matchSig nil =
	    (T.signal (T.FailGoal (tag, H, (fn () => (G, I.EClo ps'))));
	     ())			(* return indicates failure *)
	  | matchSig ((H as I.Const c)::sgn') =
	    let
	      val SClause(r) = sProgLookup c
	    in
	      (* trail to undo EVar instantiations *)
	      if
		Trail.trail
		(fn () =>
		 ((* traceMsg (fn () => "Trying clause ");
		   traceInfo (fn () => N.constName c); *)
		  rSolve (ps', (r, I.id), dProg, H,
			  (fn S =>
			   ((* traceMsg (fn () => "Succeeded clause ");
			     traceInfo (fn () => N.constName c); *)
			    sc (I.Root(H, S)))))
		(* traceMsg (fn () => "Failed clause ");
		 traceInfo (fn () => N.constName c) *) ))
		then (* deep backtracking *)
		  T.signal (T.RetryGoal (tag, H, (fn () => (G, I.EClo ps'))))
	      else (); (* shallow backtracking *)
	      matchSig sgn'
	    end

        (* matchDProg (dPool, k) = ()
	   where k is the index of dPool in global dPool from call to matchAtom.
           Try each local assumption for solving atomic goal ps', starting
           with the most recent one.
        *)
	fun matchDProg (I.Null, _) =
	    (* dynamic program exhausted, try signature *)
	    matchSig (Index.lookup a) 
	  | matchDProg (I.Decl (dPool', SOME(r, s, a')), k) =
	    if a = a'
	      then (* trail to undo EVar instantiations *)
		(if
		   Trail.trail
		   (fn () =>
		    ((* traceMsg (fn () => "Trying hypothesis ");
		      traceInfo (fn () => N.bvarName (G, k)); *)
		     rSolve (ps', (r, I.comp(s, I.Shift(k))), dProg, I.BVar(k),
			     (fn S => ((* traceMsg (fn () => "Succeeded hypothesis ");
					traceInfo (fn () => N.bvarName (G, k)); *)
				       sc (I.Root(I.BVar(k), S)))))
		   (* traceMsg (fn () => "Failed hypothesis ");
		    traceInfo (fn () => N.bvarName (G, k)); *)))
		   then (* deep backtracking *)
		     T.signal (T.RetryGoal (tag, H, (fn () => (G, I.EClo ps'))))
		 else ();
		 matchDProg (dPool', k+1))
	    else matchDProg (dPool', k+1)
	  | matchDProg (I.Decl (dPool', NONE), k) =
	      matchDProg (dPool', k+1)
      in
	matchDProg (dPool, 1)
      end


  val solve = fn (gs, dProg, sc) =>
                 (T.init (); solve (gs, dProg, sc))
  val rSolve = fn (ps', rs, dProg, sc) =>
                  (rSolve (ps', rs, dProg, I.BVar 0, sc); ())
  end (* local ... *)

end; (* functor TMachine *)
