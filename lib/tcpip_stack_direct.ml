(*
 * Copyright (c) 2011-2014 Anil Madhavapeddy <anil@recoil.org>
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

type direct_ipv4_input = src:Ipaddr.V4.t -> dst:Ipaddr.V4.t -> Cstruct.t -> unit Lwt.t
module type UDPV4_DIRECT = V1_LWT.UDPV4
  with type ipv4input = direct_ipv4_input

module type TCPV4_DIRECT = V1_LWT.TCPV4
  with type ipv4input = direct_ipv4_input

module Make
    (Console : V1_LWT.CONSOLE)
    (Time    : V1_LWT.TIME) 
    (Random  : V1.RANDOM)
    (Netif   : V1_LWT.NETWORK)
    (Ethif   : V1_LWT.ETHIF with type netif = Netif.t)
    (Ipv4    : V1_LWT.IPV4 with type ethif = Ethif.t)
    (Udpv4   : UDPV4_DIRECT with type ipv4 = Ipv4.t)
    (Tcpv4   : TCPV4_DIRECT with type ipv4 = Ipv4.t) = struct

  type +'a io = 'a Lwt.t
  type ('a,'b,'c) config = ('a,'b,'c) V1_LWT.stackv4_config
  type console = Console.t
  type netif = Netif.t
  type mode = V1_LWT.direct_stack_config
  type id = (console, netif, mode) config
  type buffer = Cstruct.t
  type ipv4addr = Ipaddr.V4.t
  type tcpv4 = Tcpv4.t
  type udpv4 = Udpv4.t
  type ipv4 = Ipv4.t

  module UDPV4 = Udpv4
  module TCPV4 = Tcpv4
  module IPV4  = Ipv4
  module Dhcp = Dhcp_clientv4.Make(Console)(Time)(Random)(Ethif)(Ipv4)(Udpv4)

  type t = {
    id    : id;
    mode  : mode;
    c     : Console.t;
    netif : Netif.t;
    ethif : Ethif.t;
    ipv4  : Ipv4.t;
    udpv4 : Udpv4.t;
    tcpv4 : Tcpv4.t;
    udpv4_listeners: (int, Udpv4.callback) Hashtbl.t;
    tcpv4_listeners: (int, (Tcpv4.flow -> unit Lwt.t)) Hashtbl.t;
  }

  type error = [
    `Unknown of string
  ]

  let id {id} = id
  let tcpv4 {tcpv4} = tcpv4
  let udpv4 {udpv4} = udpv4
  let ipv4 {ipv4} = ipv4

  let listen_udpv4 t ~port callback =
    Hashtbl.replace t.udpv4_listeners port callback

  let listen_tcpv4 t ~port callback =
    Hashtbl.replace t.tcpv4_listeners port callback

  let configure t config =
    match config with
    | `DHCP -> begin
        (* TODO: spawn a background thread to reconfigure the interface
           when future offers are received. *)
        let dhcp, offers = Dhcp.create t.c t.ipv4 t.udpv4 in
        listen_udpv4 t 68 (Dhcp.input dhcp);
        (* TODO: stop listening to this port when done with DHCP. *)
        Lwt_stream.get offers
        >>= function
        | None -> fail (Failure "No DHCP offer received")
        | Some offer -> Console.log_s t.c "DHCP offer received and bound"
      end
    | `IPv4 (addr, netmask, gateways) ->
      Console.log_s t.c (Printf.sprintf "Manager: Interface to %s nm %s gw [%s]\n%!" 
                           (Ipaddr.V4.to_string addr)
                           (Ipaddr.V4.to_string netmask)
                           (String.concat ", " (List.map Ipaddr.V4.to_string gateways)))
      >>= fun () ->
      Ipv4.set_ipv4 t.ipv4 addr
      >>= fun () ->
      Ipv4.set_ipv4_netmask t.ipv4 netmask
      >>= fun () ->
      Ipv4.set_ipv4_gateways t.ipv4 gateways

  let udpv4_listeners t ~dst_port =
    try Some (Hashtbl.find t.udpv4_listeners dst_port)
    with Not_found -> None

  let tcpv4_listeners t dst_port =
    try Some (Hashtbl.find t.tcpv4_listeners dst_port)
    with Not_found -> None

  let listen t =
    Netif.listen t.netif (
      Ethif.input
        ~ipv4:(
          Ipv4.input
            ~tcp:(Tcpv4.input t.tcpv4 
                    ~listeners:(tcpv4_listeners t))
            ~udp:(Udpv4.input t.udpv4
                    ~listeners:(udpv4_listeners t))
            ~default:(fun ~proto ~src ~dst buf -> return ())
            t.ipv4)
         ~ipv6:(fun b -> return ())
       t.ethif)

  let connect id =
    let {V1_LWT.console = c; interface = netif; mode; name } = id in
    let or_error fn t err =
      fn t
      >>= function
      | `Error e -> fail (Failure err)
      | `Ok r -> return r
    in
    Console.log_s c "Manager: connect"
    >>= fun () ->
    or_error Ethif.connect netif "ethif"
    >>= fun ethif ->
    or_error Ipv4.connect ethif "ipv4"
    >>= fun ipv4 ->
    or_error Udpv4.connect ipv4 "udpv4"
    >>= fun udpv4 ->
    or_error Tcpv4.connect ipv4 "tcpv4"
    >>= fun tcpv4 ->
    let udpv4_listeners = Hashtbl.create 7 in
    let tcpv4_listeners = Hashtbl.create 7 in
    let t = { id; c; mode; netif; ethif; ipv4; tcpv4; udpv4;
      udpv4_listeners; tcpv4_listeners } in
    Console.log_s t.c "Manager: configuring"
    >>= fun () ->
    let _ = listen t in
    configure t t.mode
    >>= fun () ->
    (* TODO: this is fine for now, because the DHCP state machine isn't fully 
       implemented and its thread will terminate after one successful lease 
       transaction.  For a DHCP thread that runs forever, `configure` will need
       to spawn a background thread, but we need to consider how to inform the
       application stack that the IP address has changed (perhaps via a control
       Lwt_stream that the application can ignore if it doesn't care). *)
    Console.log_s t.c "Manager: configuration done"
    >>= fun () ->
    return (`Ok t)

  let disconnect t =
    (* TODO: kill the listening thread *)
    Console.log_s t.c "Manager: disconnect"

  let get_state t sexp = Tcpv4.get_state t.tcpv4 sexp
  let set_state t sexp = Tcpv4.set_state t.tcpv4 ~listeners:(tcpv4_listeners t) sexp
    
end
