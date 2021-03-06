(*
 * Copyright (c) 2012 Anil Madhavapeddy <anil@recoil.org>
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
open Printf
open Wire_structs.Tcp_wire
open Sexplib.Std

let get_options buf =
  if get_data_offset buf > 20 then
    Options.unmarshal (Cstruct.shift buf sizeof_tcpv4) else []

let set_options buf ts =
  Options.marshal buf ts

let get_payload buf =
  Cstruct.shift buf (get_data_offset buf)

(* Note: since just one pbuf is used for all chksum calculations,
   the call to ones_complement_list should never block *)
let pbuf = Cstruct.sub (Cstruct.of_bigarray (Io_page.get 1)) 0 sizeof_tcpv4_pseudo_header 
let checksum ~src ~dst =
  fun data ->
    set_tcpv4_pseudo_header_src pbuf (Ipaddr.V4.to_int32 src);
    set_tcpv4_pseudo_header_dst pbuf (Ipaddr.V4.to_int32 dst);
    set_tcpv4_pseudo_header_res pbuf 0;
    set_tcpv4_pseudo_header_proto pbuf 6;
    set_tcpv4_pseudo_header_len pbuf (Cstruct.lenv data);
    Tcpip_checksum.ones_complement_list (pbuf::data)

type id = {
  dest_port: int;               (* Remote TCP port *)
  dest_ip: Ipaddr.V4.t;         (* Remote IP address *)
  local_port: int;              (* Local TCP port *)
  local_ip: Ipaddr.V4.t;        (* Local IP address *)
} with sexp

module Make (Ipv4:V1_LWT.IPV4) = struct
(* Output a general TCP packet, checksum it, and if a reference is provided,
   also record the sent packet for retranmission purposes *)
let xmit ~ip ~id ?(rst=false) ?(syn=false) ?(fin=false) ?(psh=false)
  ~rx_ack ~seq ~window ~options datav =
  printf "[DEBUG] Wire.xmit\n";
  (* Make a TCP/IP header frame *)
  lwt (ethernet_frame, header_len) =
    Ipv4.allocate_frame ~proto:`TCP ~dest_ip:id.dest_ip ip in
  (* Shift this out by the combined ethernet + IP header sizes *)
  let tcp_frame = Cstruct.shift ethernet_frame header_len in
  (* Append the TCP options to the header *)
  let options_frame = Cstruct.shift tcp_frame sizeof_tcpv4 in
  let options_len =
    match options with
    |[] -> 0
    |options -> Options.marshal options_frame options
  in
  (* At this point, extend the IPv4 view by the TCP+options size *)
  let ethernet_frame = Cstruct.set_len ethernet_frame (header_len + sizeof_tcpv4 + options_len) in
  let sequence = Sequence.to_int32 seq in
  let ack_number = match rx_ack with Some n -> Sequence.to_int32 n |None -> 0l in
  let data_off = (sizeof_tcpv4 / 4) + (options_len / 4) in
  set_tcpv4_src_port tcp_frame id.local_port;
  set_tcpv4_dst_port tcp_frame id.dest_port;
  set_tcpv4_sequence tcp_frame sequence;
  set_tcpv4_ack_number tcp_frame ack_number;
  set_data_offset tcp_frame data_off;
  set_tcpv4_flags tcp_frame 0;
  if rx_ack <> None then set_ack tcp_frame;
  if rst then set_rst tcp_frame;
  if syn then set_syn tcp_frame;
  if fin then set_fin tcp_frame;
  if psh then set_psh tcp_frame;
  set_tcpv4_window tcp_frame window;
  set_tcpv4_checksum tcp_frame 0;
  set_tcpv4_urg_ptr tcp_frame 0;
  let header = Cstruct.shift ethernet_frame header_len in
  let checksum = checksum ~src:id.local_ip ~dst:id.dest_ip (header::datav) in
  set_tcpv4_checksum tcp_frame checksum;
  printf "TCP.xmit checksum %04x %s.%d->%s.%d rst %b syn %b fin %b psh %b seq %lu ack %lu %s datalen %d datafrag %d dataoff %d olen %d\n%!"
    checksum
    (Ipaddr.V4.to_string id.local_ip) id.local_port (Ipaddr.V4.to_string id.dest_ip) id.dest_port
    rst syn fin psh sequence ack_number (Options.prettyprint options) 
    (Cstruct.lenv datav) (List.length datav) data_off options_len;
  Ipv4.writev ip ethernet_frame datav
end
