(*
 * Copyright (c) 2010 http://github.com/barko 00336ea19fcb53de187740c490f764f4
 * Copyright (c) 2011 Anil Madhavapeddy <anil@recoil.org>
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
open Sexplib.Std

(* A bounded queue to receive data segments and let readers block on 
   receiving them. Also supports a monitor that is informed when the
   queue size changes *)
module Rx = struct
  
  type t = {
    q: Cstruct.t option Lwt_sequence.t; 
    wnd: Window.t;
    writers: unit Lwt.u Lwt_sequence.t;
    readers: Cstruct.t option Lwt.u Lwt_sequence.t;
    mutable watcher: int32 Lwt_mvar.t option;
    mutable max_size: int32;
    mutable cur_size: int32;
  }

  type t_snapshot = {
    s_q: Cstruct.t option list;
    s_cur_size: int32;
  } with sexp

  let sexp_of_t t =
    let s_q = Lwt_sequence.fold_r (fun seg acc -> seg::acc) t.q [] in
    sexp_of_t_snapshot {s_q; s_cur_size = t.cur_size}

  let t_of_sexp ~max_size ~wnd t_sexp =
    let s_t = t_snapshot_of_sexp t_sexp in
    let q = List.fold_left (fun acc seg -> ignore(Lwt_sequence.add_r seg acc); acc)
                            (Lwt_sequence.create ()) s_t.s_q in
    let writers = Lwt_sequence.create () in
    let readers = Lwt_sequence.create () in
    let watcher = None in
    { q; wnd; writers; readers; max_size; cur_size = s_t.s_cur_size; watcher }
  
  let create ~max_size ~wnd =
    let q = Lwt_sequence.create () in
    let writers = Lwt_sequence.create () in
    let readers = Lwt_sequence.create () in
    let watcher = None in
    let cur_size = 0l in
    { q; wnd; writers; readers; max_size; cur_size; watcher }
  
  let notify_size_watcher t =
    let rx_wnd = max 0l (Int32.sub t.max_size t.cur_size) in
    Window.set_rx_wnd t.wnd rx_wnd;
    match t.watcher with
    |None -> return ()
    |Some w -> Lwt_mvar.put w t.cur_size
    
  let seglen s =
    match s with
    | None -> 0 
    | Some b -> Cstruct.len b

  let add_r t s =
    printf "[DEBUG] URX.add_r: cur_size=%lu max_size=%lu\n" t.cur_size t.max_size;
    if t.cur_size > t.max_size then
      let th,u = Lwt.task () in
      let node = Lwt_sequence.add_r u t.writers in
      Lwt.on_cancel th (fun _ -> Lwt_sequence.remove node);
      (* Update size before blocking, which may push cur_size above max_size *)
      t.cur_size <- Int32.(add t.cur_size (of_int (seglen s)));
      notify_size_watcher t >>
      lwt () = th in
      ignore(Lwt_sequence.add_r s t.q);
      return ()
    else begin
      (match Lwt_sequence.take_opt_l t.readers with
      |None ->
        t.cur_size <- Int32.(add t.cur_size (of_int (seglen s)));
        ignore(Lwt_sequence.add_r s t.q);
        notify_size_watcher t
      |Some u -> 
        return (Lwt.wakeup_later u s)   (* XXX: currently for consistent state snapshot *)
      );
    end
      
  let take_l t =
    if Lwt_sequence.is_empty t.q then begin
      let th,u = Lwt.task () in
      let node = Lwt_sequence.add_r u t.readers in
      Lwt.on_cancel th (fun _ -> Lwt_sequence.remove node);
      th
    end else begin
      let s = Lwt_sequence.take_l t.q in
      t.cur_size <- Int32.(sub t.cur_size (of_int (seglen s)));
      notify_size_watcher t >>
      if t.cur_size < t.max_size then begin
        match Lwt_sequence.take_opt_l t.writers with
        |None -> ()
        |Some w -> Lwt.wakeup w ()
      end;
      return s
    end
  
  let cur_size t = t.cur_size
  let max_size t = t.max_size
  
  let monitor t mvar =
    t.watcher <- Some mvar

end

(* The transmit queue simply advertises how much data is allowed to be
   written, and a wakener for when it is full. It is up to the application
   to decide how to throttle or breakup its data production with this
   information.
*)
module Tx(Time:V1_LWT.TIME)(Clock:V1.CLOCK) = struct

  module TXS = Segment.Tx(Time)(Clock)

  type t = {
    wnd: Window.t;
    writers: bool Lwt.u Lwt_sequence.t;
    txq: TXS.q;
    buffer: Cstruct.t Lwt_sequence.t;
    max_size: int32;
    mutable bufbytes: int32;
  }

  exception Write_suspended

  type t_snapshot = {
    s_buffer: Cstruct.t list;
    s_max_size: int32;
    s_bufbytes: int32;
  } with sexp

  let sexp_of_t t =
    let s_buffer = Lwt_sequence.fold_r (fun seg acc -> seg::acc) t.buffer [] in
    (* XXX: Lwt cancel test *)
    let wake_writer () = 
      match Lwt_sequence.take_opt_l t.writers with
      | None -> ()
      | Some w -> Lwt.wakeup w false in
    wake_writer ();
    sexp_of_t_snapshot {s_buffer; s_max_size = t.max_size; s_bufbytes = t.bufbytes}

  let t_of_sexp ~wnd ~txq t_sexp =
    let s_t = t_snapshot_of_sexp t_sexp in
    let buffer = List.fold_left (fun acc seg -> ignore(Lwt_sequence.add_r seg acc); acc)
                            (Lwt_sequence.create ()) s_t.s_buffer in
    let writers = Lwt_sequence.create () in
    { wnd; writers; txq; buffer; max_size = s_t.s_max_size; bufbytes = s_t.s_bufbytes }

  let create ~max_size ~wnd ~txq = 
    let buffer = Lwt_sequence.create () in
    let writers = Lwt_sequence.create () in
    let bufbytes = 0l in
    { wnd; writers; txq; buffer; max_size; bufbytes }

  let len data = 
    Int32.of_int (Cstruct.len data)

  let lenv datav =
    match datav with
    |[] -> 0l
    |[d] -> Int32.of_int (Cstruct.len d)
    |ds -> Int32.of_int (List.fold_left (fun a b -> Cstruct.len b + a) 0 ds)

  (* Check how many bytes are available to write to output buffer *)
  let available t = 
    let a = Int32.sub t.max_size t.bufbytes in
    match a < (Int32.of_int (Window.tx_mss t.wnd)) with
    | true -> 0l
    | false -> a

  (* Check how many bytes are available to write to wire *)
  let available_cwnd t = 
    Window.tx_available t.wnd

  (* Wait until at least sz bytes are available in the window *)
  let rec wait_for t sz =
    if (available t) >= sz then begin
      return ()
    end
    else begin
      let th,u = Lwt.task () in
      let node = Lwt_sequence.add_r u t.writers in
      Lwt.on_cancel th (fun _ -> Lwt_sequence.remove node);
      printf "[DEBUG] UTX.wait_for: sz=%d\n" (Int32.to_int sz);
      th >>= function
      | true -> wait_for t sz
      | false -> 
          printf "[DEBUG] try to cancel a writer\n";
          Lwt.fail Write_suspended
    end

  let compactbufs bl =
    (* TODO: fix hardecoded threshold *)
    if (List.length bl > 8) then begin
      let b = Io_page.(to_cstruct (get 1)) in
      let copyf doff ab =
	Cstruct.blit ab 0 b doff (Cstruct.len ab);
	doff + (Cstruct.len ab)
      in
      let l = List.fold_left copyf 0 bl in
      let b = Cstruct.sub b 0 l in
      [b]
    end else begin
      bl
    end

  (* Wait until the user buffer is flushed *)
  let rec wait_for_flushed t =
    if Lwt_sequence.is_empty t.buffer then begin
      return ()
    end
    else begin
      let th,u = Lwt.task () in
      let node = Lwt_sequence.add_r u t.writers in
      Lwt.on_cancel th (fun _ -> Lwt_sequence.remove node);
      th >>= function
      | true -> wait_for_flushed t
      | false -> 
          printf "[DEBUG] try to cancel a writer\n";
          Lwt.fail Write_suspended
    end

  let rec clear_buffer t = 
    printf "[DEBUG] UTX.clear_buffer\n";
    let rec addon_more curr_data l =
      match Lwt_sequence.take_opt_l t.buffer with
      | None ->
          (* printf "out at 1\n%!";*)
	  List.rev curr_data
      | Some s ->
          let s_len = len s in
          match s_len > l with
          | true -> 
              (*printf "out at 2 %lu %lu\n%!" s_len l;*)
              let _ = Lwt_sequence.add_l s t.buffer in
              List.rev curr_data
          | false -> 
	      t.bufbytes <- Int32.sub t.bufbytes s_len;
              addon_more (s::curr_data) (Int32.sub l s_len)
    in
    let get_pkt_to_send () =
      let avail_len = min (available_cwnd t) (Int32.of_int (Window.tx_mss t.wnd)) in
      let s = Lwt_sequence.take_l t.buffer in
      let s_len = len s in
      match s_len > avail_len with
      | true ->  begin
          match avail_len with
          |0l -> (* return pkt to buffer *)
            let _ = Lwt_sequence.add_l s t.buffer in
            None
          |_ -> (* split buffer into a partial write *)
            let to_send,remaining = Cstruct.split s (Int32.to_int avail_len) in
            (* queue remaining view *)
            let _ = Lwt_sequence.add_l remaining t.buffer in
            t.bufbytes <- Int32.sub t.bufbytes avail_len;
            Some [to_send]
      end
      | false -> 
          match s_len < avail_len with
          | true -> 
	      t.bufbytes <- Int32.sub t.bufbytes s_len;
	      Some (addon_more (s::[]) (Int32.sub avail_len s_len))
          | false -> 
	      t.bufbytes <- Int32.sub t.bufbytes s_len;
	      Some [s]
    in
    match Lwt_sequence.is_empty t.buffer with
    | true -> return ()
    | false -> 
        match get_pkt_to_send () with
        | None -> return ()
        | Some pkt -> 
	    let b = compactbufs pkt in
            TXS.output ~flags:Segment.Psh t.txq b >>
            clear_buffer t

  (* Chunk up the segments into MSS max for transmission *)
  let transmit_segments ~mss ~txq datav =
    printf "[DEBUG] UTX.transmit_segments\n";
    let transmit acc = 
      let b = compactbufs (List.rev acc) in
      TXS.output ~flags:Segment.Psh txq b
    in
    let rec chunk datav acc =
      match datav with
      |[] -> begin
        match acc with
        |[] -> return ()
        |_ -> transmit acc
      end 
      |hd::tl ->
        let curlen = Cstruct.lenv acc in
        let tlen = Cstruct.len hd + curlen in
        if tlen > mss then begin
          let a,b = Cstruct.split hd (mss - curlen) in
          lwt () = transmit (a::acc) in
          chunk (b::tl) []
        end else
          chunk tl (hd::acc)
    in
    chunk datav []

  let write t datav =
    let l = lenv datav in
    let mss = Int32.of_int (Window.tx_mss t.wnd) in
    printf "[DEBUG] UTX.write: len=%lu mss=%lu\n" l mss;
    match Lwt_sequence.is_empty t.buffer &&
      (l = mss || not (Window.tx_inflight t.wnd)) with
    | false -> 
	t.bufbytes <- Int32.add t.bufbytes l;
        List.iter (fun data -> ignore(Lwt_sequence.add_r data t.buffer)) datav;
	if t.bufbytes < mss then
          return ()
	else
	  clear_buffer t
    | true -> 
	let avail_len = available_cwnd t in
        match avail_len < l with
	| true -> 
	    t.bufbytes <- Int32.add t.bufbytes l;
            List.iter (fun data -> ignore(Lwt_sequence.add_r data t.buffer)) datav;
            return ()
	| false -> 
            let max_size = Window.tx_mss t.wnd in
            transmit_segments ~mss:max_size ~txq:t.txq datav
            
  let write_nodelay t datav =
    let l = lenv datav in
    match Lwt_sequence.is_empty t.buffer with
    | false -> 
	t.bufbytes <- Int32.add t.bufbytes l;
        List.iter (fun data -> ignore(Lwt_sequence.add_r data t.buffer)) datav;
        return ()
    | true -> 
	let avail_len = available_cwnd t in
        match avail_len < l with
	| true -> 
	    t.bufbytes <- Int32.add t.bufbytes l;
            List.iter (fun data -> ignore(Lwt_sequence.add_r data t.buffer)) datav;
            return ()
	| false -> 
            let max_size = Window.tx_mss t.wnd in
            transmit_segments ~mss:max_size ~txq:t.txq datav


  let inform_app t = 
    match Lwt_sequence.take_opt_l t.writers with
    | None -> return ()
    | Some w ->
  printf "[DEBUG] UTX.inform: wakeup\n";
	Lwt.wakeup w true;
	return ()

  (* Indicate that more bytes are available for waiting writers.
     Note that sz does not take window scaling into account, and so
     should be passed as unscaled (i.e. from the wire) here.
     Window will internally scale it up. *)
  let free t sz =
    printf "[DEBUG] UTX.free: sz=%d\n" sz;
    clear_buffer t >>
    inform_app t
   
end
