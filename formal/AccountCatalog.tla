--------------------------- MODULE AccountCatalog ---------------------------
(***************************************************************************)
(* accounts-v1.json shared by the app and CLI processes.                   *)
(*                                                                         *)
(* Code (Sources/VikingBarCore/Accounts.swift):                            *)
(*   AccountCatalog.transaction  catalog.lock, readExisting, edit, write   *)
(*                               .catalog-UUID.tmp, synchronize, rename    *)
(*   AccountCatalog.reserve / select(_:replacing:) / snapshot              *)
(*   AccountCatalog.selectedAtInvocation  reads without the lock           *)
(*                                                                         *)
(* One Writer is one reserve or select transaction. Steps: flock (busy     *)
(* throws), read the file, write the temporary file, rename it over        *)
(* accounts-v1.json, release. A crash can happen after any step; the       *)
(* kernel releases the flock and the temporary file is left behind or      *)
(* unlinked, never renamed. Readers read the file without the lock; a      *)
(* rename is atomic, so a reader sees one whole version.                   *)
(*                                                                         *)
(* Faithful* constants are TRUE for the code as written; each mutant in    *)
(* formal/mutants/AccountCatalog turns one off.                            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Writers,
    Slots,                     \* account slots a writer may reserve or select
    \* transaction: catalog.lock held from before the read until after rename.
    FaithfulLockAroundEdit,
    \* transaction: write a temporary file, then rename it into place.
    FaithfulAtomicReplace,
    \* select: guard snapshot.accounts.contains(key) else invalidSelection.
    FaithfulSelectChecksListed

Legacy == "legacy"
None == "none"

VARIABLES
    lock,      \* writer holding catalog.lock, or None
    file,      \* accounts-v1.json: [accounts, selected]; torn = a half-written file
    pc, edited, goal,
    reserved,  \* history: slots whose reserve returned success
    torn       \* history: a reader could see a half-written file

vars == <<lock, file, pc, edited, goal, reserved, torn>>

Default == [accounts |-> {Legacy}, selected |-> Legacy]

Init ==
    /\ lock = None
    /\ file = Default
    /\ pc = [w \in Writers |-> "idle"]
    /\ edited = [w \in Writers |-> Default]
    /\ goal = [w \in Writers |-> [op |-> "none", slot |-> Legacy, replacing |-> None]]
    /\ reserved = {}
    /\ torn = FALSE

\* reserve(provider:label:) or select(_:replacing:) starts.
Start(w) ==
    /\ pc[w] = "idle"
    /\ \E g \in [op : {"reserve"}, slot : Slots, replacing : {None}]
               \cup [op : {"select"}, slot : Slots \cup {Legacy}, replacing : Slots \cup {Legacy, None}] :
           goal' = [goal EXCEPT ![w] = g]
    /\ pc' = [pc EXCEPT ![w] = IF FaithfulLockAroundEdit THEN "locking" ELSE "reading"]
    /\ UNCHANGED <<lock, file, edited, reserved, torn>>

Lock(w) ==
    /\ pc[w] = "locking"
    /\ lock = None
    /\ lock' = w
    /\ pc' = [pc EXCEPT ![w] = "reading"]
    /\ UNCHANGED <<file, edited, goal, reserved, torn>>

\* readExisting + edit. A select of an unlisted slot throws invalidSelection.
\* An unchanged snapshot is not written.
Read(w) ==
    /\ pc[w] = "reading"
    /\ LET g == goal[w]
           e == IF g.op = "reserve"
                THEN [file EXCEPT !.accounts = @ \cup {g.slot}]
                ELSE IF g.replacing = None \/ file.selected = g.replacing
                     THEN [file EXCEPT !.selected = g.slot] ELSE file
       IN IF g.op = "select" /\ g.slot \notin file.accounts /\ FaithfulSelectChecksListed
          THEN /\ pc' = [pc EXCEPT ![w] = "releasing"]
               /\ UNCHANGED edited
          ELSE /\ edited' = [edited EXCEPT ![w] = e]
               /\ pc' = [pc EXCEPT ![w] = IF e = file THEN "releasing" ELSE "writing"]
    /\ UNCHANGED <<lock, file, goal, reserved, torn>>

\* Write .catalog-UUID.tmp and synchronize, or (mutant) write in place.
Write(w) ==
    /\ pc[w] = "writing"
    /\ torn' = (torn \/ ~FaithfulAtomicReplace)
    /\ pc' = [pc EXCEPT ![w] = "renaming"]
    /\ UNCHANGED <<lock, file, edited, goal, reserved>>

\* rename(temporary, accounts-v1.json): the new version appears whole.
Rename(w) ==
    /\ pc[w] = "renaming"
    /\ file' = edited[w]
    /\ pc' = [pc EXCEPT ![w] = "releasing"]
    /\ UNCHANGED <<lock, edited, goal, reserved, torn>>

\* defer lease.release(); reserve returns its entry.
Release(w) ==
    /\ pc[w] = "releasing"
    /\ lock' = IF lock = w THEN None ELSE lock
    /\ reserved' = IF goal[w].op = "reserve" /\ goal[w].slot \in edited[w].accounts
                   THEN reserved \cup {goal[w].slot} ELSE reserved
    /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<file, edited, goal, torn>>

Crash(w) ==
    /\ pc[w] # "idle"
    /\ lock' = IF lock = w THEN None ELSE lock
    /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<file, edited, goal, reserved, torn>>

Next ==
    \E w \in Writers :
        Start(w) \/ Lock(w) \/ Read(w) \/ Write(w) \/ Rename(w) \/ Release(w) \/ Crash(w)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules.                                                                  *)

\* A slot whose reservation succeeded stays listed. Harm: an added account
\* disappears, and its Keychain session and cache become unreachable.
NoLostReservation == reserved \subseteq file.accounts

\* The stored selection is a listed account. Harm: readExisting rejects the
\* catalog and every app and CLI start fails with a storage error.
SelectedIsListed == file.selected \in file.accounts

\* No reader can see a half-written file. Harm: same as above, on a crash
\* or a concurrent read.
NoTornFile == ~torn

=============================================================================
