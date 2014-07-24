(*
 * Copyright (c) 2012 Balraj Singh <bs375@cl.cam.ac.uk>
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

open Sexplib
open Sexplib.Std

type action =
  | Passive_open
  | Recv_rst
  | Recv_synack of Sequence.t
  | Recv_ack of Sequence.t
  | Recv_fin
  | Recv_finack of Sequence.t
  | Send_syn of Sequence.t
  | Send_synack of Sequence.t
  | Send_rst
  | Send_fin of Sequence.t
  | Timeout

type tcpstates = 
  | Closed
  | Listen
  | Syn_rcvd of Sequence.t
  | Syn_sent of Sequence.t
  | Established
  | Close_wait
  | Last_ack of Sequence.t
  | Fin_wait_1 of Sequence.t
  | Fin_wait_2 of int
  | Closing of Sequence.t
  | Time_wait

type close_cb = unit -> unit with sexp

type t = {
  on_close: close_cb;
  mutable state: tcpstates;
}

val state : t -> tcpstates
val t : on_close:close_cb -> t
val sexp_of_t : t -> Sexp.t
val t_of_sexp : on_close:close_cb -> Sexp.t -> t
val tcpstates_to_string : tcpstates -> string

module Make(Time : V1_LWT.TIME) : sig
  val fin_wait_2_time : float
  val time_wait_time : float
  val finwait2timer : t -> int -> float -> unit Lwt.t
  val timewait : t -> float -> unit Lwt.t
  val tick : t -> action -> unit
end
