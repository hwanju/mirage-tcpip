(*
 * Copyright (c) 2010 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open State
open Sexplib

module Rx (T:V1_LWT.TIME) : sig
    type seg
    val make: sequence:Sequence.t -> fin:bool -> syn:bool -> ack:bool ->
      ack_number:Sequence.t -> window:int -> data:Cstruct.t -> seg

    type q
    val q : rx_data:(Cstruct.t list option * int option) Lwt_mvar.t ->
      wnd:Window.t -> state:State.t ->
      tx_ack:(Sequence.t * int) Lwt_mvar.t -> q
    val sexp_of_q : q -> Sexp.t
    val q_of_sexp : rx_data:(Cstruct.t list option * int option) Lwt_mvar.t ->
      wnd:Window.t -> state:State.t ->
      tx_ack:(Sequence.t * int) Lwt_mvar.t -> Sexp.t -> q
    val to_string : q -> string
    val is_empty : q -> bool
    val input : q -> seg -> unit Lwt.t
  end

type tx_flags = |No_flags |Syn |Fin |Rst |Psh

(* Pre-transmission queue *)
module Tx (Time:V1_LWT.TIME)(Clock:V1.CLOCK) : sig

    type xmit = flags:tx_flags -> wnd:Window.t -> options:Options.ts ->
      seq:Sequence.t -> Cstruct.t list -> unit Lwt.t

    type q

    val q : xmit:xmit -> wnd:Window.t -> state:State.t ->
      rx_ack:Sequence.t Lwt_mvar.t ->
      tx_ack:(Sequence.t * int) Lwt_mvar.t ->
      tx_wnd_update:int Lwt_mvar.t -> q * unit Lwt.t

    val sexp_of_q : q -> Sexp.t
    val q_of_sexp : xmit:xmit -> wnd:Window.t -> state:State.t ->
      rx_ack:Sequence.t Lwt_mvar.t ->
      tx_ack:(Sequence.t * int) Lwt_mvar.t ->
      tx_wnd_update:int Lwt_mvar.t -> Sexp.t -> q * unit Lwt.t

    val output : ?flags:tx_flags -> ?options:Options.ts -> q -> Cstruct.t list -> unit Lwt.t
   
  end
