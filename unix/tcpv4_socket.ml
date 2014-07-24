(*
 * Copyright (c) 2014 Anil Madhavapeddy <anil@recoil.org>
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

open Lwt

type buffer = Cstruct.t
type ipv4addr = Ipaddr.V4.t
type flow = Lwt_unix.file_descr
type +'a io = 'a Lwt.t
type ipv4 = Ipaddr.V4.t option (* interface *)
type ipv4input = unit io
type callback = flow -> unit io

type t = {
  interface: Unix.inet_addr option;    (* source ip to bind to *)
}

(** IO operation errors *)
type error = [
  | `Unknown of string (** an undiagnosed error *)
  | `Timeout
  | `Refused
]

let connect id =
  let t =
    match id with
    | None -> { interface=None }
    | Some ip -> { interface=Some (Ipaddr_unix.V4.to_inet_addr ip) }
  in
  return (`Ok t)

let disconnect _ =
  return ()

let id {interface} =
  match interface with
  | None -> None
  | Some i -> Some (Ipaddr_unix.V4.of_inet_addr_exn i)

let get_dest fd =
  match Lwt_unix.getpeername fd with
  | Unix.ADDR_UNIX _ ->
    raise (Failure "unexpected: got a unix instead of tcp sock")
  | Unix.ADDR_INET (ia,port) -> begin
      match Ipaddr_unix.V4.of_inet_addr ia with
      | None -> raise (Failure "got a ipv6 sock instead of a tcpv4 one")
      | Some ip -> ip,port
    end

let create_connection t (dst,dst_port) =
  let fd = Lwt_unix.socket Lwt_unix.PF_INET Lwt_unix.SOCK_STREAM 0 in
  try_lwt
    Lwt_unix.connect fd
      (Lwt_unix.ADDR_INET ((Ipaddr_unix.V4.to_inet_addr dst), dst_port))
    >>= fun () ->
    return (`Ok fd)
  with exn ->
    return (`Error (`Unknown (Printexc.to_string exn)))

let read fd =
  let buflen = 4096 in
  let buf = Cstruct.create buflen in
  try_lwt
    Lwt_cstruct.read fd buf 
    >>= function
    | 0 -> return `Eof
    | n when n = buflen -> return (`Ok buf)
    | n -> return (`Ok (Cstruct.sub buf 0 n))
  with exn ->
    return (`Error (`Unknown (Printexc.to_string exn)))

let rec write fd buf =
  match_lwt Lwt_cstruct.write fd buf with
  | n when n = Cstruct.len buf -> return ()
  | n -> write fd (Cstruct.sub buf n (Cstruct.len buf - n))

let writev fd bufs =
  Lwt_list.iter_s (write fd) bufs

(* TODO make nodelay a flow option *)
let write_nodelay fd buf =
  write fd buf

(* TODO make nodelay a flow option *)
let writev_nodelay fd bufs =
  writev fd bufs

let close fd =
  Lwt_unix.close fd

let input t ~listeners =
  (* TODO terminate when signalled by disconnect *)
  let t,u = Lwt.task () in
  t

(* NOT implemented *)
let get_state t sexp = None
let set_state t ~listeners sexp = None
