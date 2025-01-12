(* Dummy mode tests *)
open Smapi_types
open Ocamltest

open Vhd_types
open Int_types

open Listext
open Stringext
open Threadext
open Vhd_records

module D=Debug.Debugger(struct let name="dummytests" end)
open D

module SC=Smapi_client

let real = ref false

let can_create_raw = ref true

let meg = Int64.mul 1024L 1024L
let stddisksize = Int64.mul 50L meg
let smallerdisksize = Int64.mul 40L meg

let rpc host port path ?task_id xml = 
  let open Xmlrpc_client in
      XML_protocol.rpc ~transport:(TCP (host,port)) ~http:(xmlrpc ~version:"1.0" path ?task_id) xml


let intrpc host port = Int_rpc.wrap_rpc (Vhdrpc.remote_rpc "dummy" host port)

let dummy_context = {
	Smapi_types.c_driver = "none";
	c_api_call = "none";
	c_task_id = "none";
	c_other_info = [];
}

type vhdd = {
	handle : Forkhelpers.pidty option;
	host_id : string;
	rpc : ?task_id:string -> Xml.xml -> Xml.xml;
	intrpc : Int_rpc.intrpc -> Int_rpc.intrpc_response_wrapper;
}

type state = {
	vhdds: vhdd list;
	gp : generic_params;
	sr : sr;
	vdis : vdi list;
}

let vhdd_path = ref "vhdd"

let pool = ref false

(** Returns the last 12 characters in a string *)
let get_last12 s =
	String.sub s (String.length s - 12) 12

module Dummy = struct
	let start_vhdd port host_id =
		let args = [
			"-dummy";
			"-dummydir"; "/tmp/dummytest";
			"-host_uuid"; host_id;
			"-port"; (string_of_int port);
			"-nodaemon";
			"-fileserver";
			"-htdocs"; "/myrepos/vhdd.hg/html";
			"-t"] in
		let handle = Forkhelpers.safe_close_and_exec ~env:[|"OCAMLRUNPARAM=b"|] None None None [] !vhdd_path args in
		let myrpc = rpc "localhost" port "/lvmnew" in
		let myintrpc = intrpc "localhost" port in
		let rec wait_for_start () =
			try
				ignore(Int_client.Debug.get_pid myintrpc);
				ignore(SC.SR.probe myrpc { gp_device_config=["device","none"];gp_xapi_params=None; gp_sr_sm_config=[]} []);
			with _ ->
				wait_for_start ()
		in
		wait_for_start ();

		{ handle = Some handle;
		host_id = host_id;
		rpc = myrpc;
		intrpc = myintrpc; }

	let kill_vhdd vhdd =
		(try Int_client.Debug.die vhdd.intrpc false with _ -> ());
		match vhdd.handle with Some h -> ignore(Forkhelpers.waitpid h) | None -> Thread.delay 2.0

	let create_and_attach vhdds =
		let master = List.hd vhdds in
		let slaves = List.tl vhdds in

		let device_config = ["device","/dev/dummy"] in

		let slave_gp = { gp_device_config=device_config; gp_xapi_params=None; gp_sr_sm_config=[] } in
		let master_gp = { slave_gp with gp_device_config=("SRmaster","true")::slave_gp.gp_device_config; } in

		let sr = {sr_uuid = "1"} in

		SC.SR.create master.rpc master_gp (Some sr) 0L;
		SC.SR.attach master.rpc master_gp (Some sr);
		List.iter (fun slave -> SC.SR.attach slave.rpc slave_gp (Some sr)) slaves;

		{ vhdds=vhdds;
		gp=slave_gp;
		sr=sr;
		vdis=[]; }

	let init () =
		let vhdds =
			(start_vhdd 4094 "1") :: (if !pool then [start_vhdd 4095 "2"] else [])
		in
		create_and_attach vhdds

	let detach_all state =
		List.iter (fun vhdd ->
			List.iter (fun vdi ->
				(try SC.VDI.deactivate vhdd.rpc state.gp (Some state.sr) vdi.vdi_location with _ -> ());
				(try SC.VDI.detach vhdd.rpc state.gp (Some state.sr) vdi.vdi_location with _ -> ())) state.vdis;
			try SC.SR.detach vhdd.rpc state.gp (Some state.sr) with _ -> ()) (List.rev state.vhdds)

	let cleanup state =
		detach_all state;
		List.iter kill_vhdd state.vhdds;
		Thread.delay 0.1;
		let unwanted_dirs = [
			"/tmp/dummytest/1/dev";
			"/tmp/dummytest/1/var/run/vhdd";
			"/tmp/dummytest/1/var/xapi";
			"/tmp/dummytest/2/dev";
			"/tmp/dummytest/2/var/run/vhdd";
			"/tmp/dummytest/2/var/xapi";
			"/tmp/dummytest/dev" ] in
		List.iter (fun dir -> ignore(Sys.command (Printf.sprintf "rm -rf %s" dir))) unwanted_dirs

end

module Real = struct

	let device_config = ref []
	let hosts = ref []
	let uri = ref "/lvmoiscsi"

	let init () =
		let make_vhdd host =
			let myrpc = rpc host 4094 !uri in
			let myintrpc = intrpc host 4094 in
			let host_id = Int_client.Debug.get_host myintrpc in
			{
				handle = None;
				host_id = host_id;
				rpc = myrpc;
				intrpc = myintrpc }
		in
		let vhdds = List.map make_vhdd !hosts in
		let sr = {sr_uuid = "1"} in
		let master = List.hd vhdds in
		let slave_gp = { gp_device_config= !device_config; gp_xapi_params=None; gp_sr_sm_config=[] } in
		let master_gp = { slave_gp with gp_device_config=("SRmaster","true")::slave_gp.gp_device_config; } in
		SC.SR.create master.rpc master_gp (Some sr) 0L;
		SC.SR.attach master.rpc master_gp (Some sr);
		Thread.delay 0.5;
		List.iter (fun slave -> SC.SR.attach slave.rpc slave_gp (Some sr)) (List.tl vhdds);
		{
			vhdds = vhdds;
			gp = slave_gp;
			sr = sr;
			vdis = []
		}

	let detach_all state =
		List.iter (fun vhdd ->
			List.iter (fun vdi ->
				(try SC.VDI.deactivate vhdd.rpc state.gp (Some state.sr) vdi.vdi_location with _ -> ());
				(try SC.VDI.detach vhdd.rpc state.gp (Some state.sr) vdi.vdi_location with _ -> ())) state.vdis;
			try SC.SR.delete vhdd.rpc state.gp (Some state.sr) with _ -> ()) (List.rev state.vhdds)

	let cleanup state =
		detach_all state


end

let init = ref Dummy.init
let cleanup = ref Dummy.cleanup

let get_chain_length state id = 
	let master = List.hd state.vhdds in
	let id_map = Int_client.Debug.get_id_to_leaf_map master.intrpc state.sr.sr_uuid in
	let vhds = Int_client.Debug.get_vhds master.intrpc state.sr.sr_uuid in
	let leaf_info = Hashtbl.find id_map id in
	match leaf_info.leaf with
		| PVhd vhduid -> 
			let (vhds,lvopt) = Vhd_records.get_vhd_chain dummy_context vhds vhduid in
			let len = List.length vhds in
			(match lvopt with 
				| Some _ -> len + 1
				| _ -> len)
		| PRaw lv -> 1

(* Check that what the master thinks is the state of the world is the the same as all of the slaves *)
let check_consistency state =
	let master = List.hd state.vhdds in
	let id_map = Int_client.Debug.get_id_to_leaf_map master.intrpc state.sr.sr_uuid in
	let vhds = Int_client.Debug.get_vhds master.intrpc state.sr.sr_uuid in
	let vhds = Vhd_records.get_vhd_hashtbl_copy dummy_context vhds in
	let container = Int_client.Debug.get_vhd_container master.intrpc state.sr.sr_uuid in

	let ctx = {Smapi_types.c_driver=""; c_api_call=""; c_task_id=""; c_other_info=[]} in
	let dm_info = Lvmabs.scan ctx container (Lvmabs.get_attach_info ctx container) in

	let check_slave slave =
		let consistent = ref true in

		let slaves_attached_vdis_according_to_master =
			Hashtbl.fold (fun k v acc ->
				match v.attachment with
					| Some (AttachedRO x) -> if List.mem slave.host_id x then k::acc else acc
					| Some (AttachedRW x) -> if List.mem slave.host_id x then k::acc else acc
					| None -> acc) id_map []
		in

		let attached_vdis = Int_client.Debug.get_attached_vdis slave.intrpc state.sr.sr_uuid in

		(* Check that the slave does have the VDIs attached that the master thinks it does *)
		List.iter (fun k ->
			if not (Hashtbl.mem attached_vdis k)
			then begin
				consistent := false;
				print_endline (Printf.sprintf "Master thought slave '%s' had VDI '%s' attached, but it doesn't!" slave.host_id k)
			end) slaves_attached_vdis_according_to_master;

		(* Check that the master agrees with the slave on which VDIs the slave thinks it has attached *)
		Hashtbl.iter (fun k v ->
			let leaf_info = Hashtbl.find id_map k in
			begin
				match leaf_info.attachment with
					| Some (AttachedRO x) -> if not (List.mem slave.host_id x) then (consistent := false; print_endline "Host is not in attachment list!")
					| Some (AttachedRW x) -> if not (List.mem slave.host_id x) then (consistent := false; print_endline "Host is not in attachment list!")
					| None -> (consistent := false; print_endline "Master doesn't think the VDI is attached at all!")
			end;

			(* Verify that the leaf is correct *)
			if v.savi_attach_info.sa_leaf_is_raw then begin
				(*print_endline (Printf.sprintf "attach_info: leaf_path (should be a RAW LV): %s" v.savi_attach_info.sa_leaf_path);*)
				let master_leaf = leaf_info.leaf in
				match master_leaf with
					| PVhd x -> print_endline (Printf.sprintf "Master believes the leaf to be a VHD! (uid=%s)" x)
					| PRaw lv -> begin
						  match lv.Lvmabs_types.location with
							  | Lvmabs_types.LogicalVolume lv ->
									let last12 = get_last12 lv in
									let last12' = get_last12 v.savi_attach_info.sa_leaf_path in
									if last12 <> last12' then begin
										consistent := false;
										print_endline (Printf.sprintf "Inconsist leaf path: Master thinks: %s Slave thinks: %s" last12 last12')
									end
							  | Lvmabs_types.OLV lv ->
									let last12 = get_last12 (Olvm.get_lv_name lv) in
									let last12' = get_last12 v.savi_attach_info.sa_leaf_path in
									if last12 <> last12' then begin
										consistent := false;
										print_endline (Printf.sprintf "Inconsist leaf path: Master thinks: %s Slave thinks: %s" last12 last12')
									end
							  | _ -> failwith "Ack"
					  end
			end else begin
				let vhduid = Int_client.Debug.slave_get_leaf_vhduid slave.intrpc state.sr.sr_uuid k in
				match leaf_info.leaf with
					| PVhd x -> if x <> vhduid then begin
						  consistent := false;
						  print_endline (Printf.sprintf "Inconsistent VHDUID: Master expecting %s, slave got %s" x vhduid)
					  end
					| PRaw lv ->
						  consistent := false;
						  print_endline
							  (Printf.sprintf "Master thinks the leaf is RAW (%s), the slave thinks it's a VHD (uid %s)"
								  (match lv.Lvmabs_types.location with
									  | Lvmabs_types.LogicalVolume x -> x
									  | Lvmabs_types.OLV x -> (Olvm.get_lv_name x)
									  | _ -> failwith "Ack!") vhduid)
			end;

			(* Verify that the LVs are consistent *)
			List.iter (fun lv ->
				match lv with
					| Mlvm d ->
						  let master_dm = List.find (fun d' -> match d' with | Mlvm d' -> d'.dmn_dm_name=d.dmn_dm_name) dm_info in
						  if master_dm <> lv then (consistent := false; print_endline (Printf.sprintf "Inconsistent: LV %s is not the same" d.dmn_dm_name))) v.savi_attach_info.sa_lvs;
		) attached_vdis;
		if !consistent then None else Some slave
	in

	List.filter_map check_slave state.vhdds

let create_vdi state size raw =
	if raw && not !can_create_raw then
		skip "Can't create RAW disks";
	let master = List.hd state.vhdds in
	let sm_config = if raw then ["type","raw"] else [] in
	let vdi = SC.VDI.create master.rpc state.gp (Some state.sr) sm_config size in
	let vdi = {vdi_uuid=None;
	vdi_location=vdi.vdi_location} in
	(vdi,{state with vdis=vdi::state.vdis})

let delete_vdi state vdi =
	let master = List.hd state.vhdds in
	SC.VDI.delete master.rpc state.gp (Some state.sr) vdi.vdi_location;
	{state with vdis = List.filter (fun vdi' -> vdi' <> vdi) state.vdis}

let attach_vdi state host_id vdi writable =
	let vhdd = List.find (fun vhdd -> vhdd.host_id = host_id) state.vhdds in
	SC.VDI.attach vhdd.rpc state.gp (Some state.sr) vdi.vdi_location writable

let activate_vdi state host_id vdi =
	let vhdd = List.find (fun vhdd -> vhdd.host_id = host_id) state.vhdds in
	SC.VDI.activate vhdd.rpc state.gp (Some state.sr) vdi.vdi_location

let detach_vdi state host_id vdi =
	let vhdd = List.find (fun vhdd -> vhdd.host_id = host_id) state.vhdds in
	SC.VDI.detach vhdd.rpc state.gp (Some state.sr) vdi.vdi_location

let deactivate_vdi state host_id vdi =
	let vhdd = List.find (fun vhdd -> vhdd.host_id = host_id) state.vhdds in
	SC.VDI.deactivate vhdd.rpc state.gp (Some state.sr) vdi.vdi_location

let resize_vdi state vdi newsize =
	let vhdd = List.hd state.vhdds in
	SC.VDI.resize vhdd.rpc state.gp (Some state.sr) [] vdi.vdi_location newsize;
	state

let resize_vdi_online state vdi newsize =
	let vhdd = List.hd state.vhdds in
	SC.VDI.resize_online vhdd.rpc state.gp (Some state.sr) [] vdi.vdi_location newsize;
	state

let write_junk state host_id vdi size n current =
	let vhdd = List.find (fun vhdd -> vhdd.host_id = host_id) state.vhdds in
	Int_client.Debug.write_junk vhdd.intrpc state.sr.sr_uuid vdi.vdi_location size n current

(* Check junk checks twice - once with the wrong junk, and once with the correct junk *)
let check_junk state host_id vdi junk =
	let vhdd = List.find (fun vhdd -> vhdd.host_id = host_id) state.vhdds in
	let success1 =
		try Int_client.Debug.check_junk vhdd.intrpc state.sr.sr_uuid vdi.vdi_location (([(0L,10L)],char_of_int 55)::junk); false with e -> true
	in
	let success2 =
		try Int_client.Debug.check_junk vhdd.intrpc state.sr.sr_uuid vdi.vdi_location junk; true with e -> false
	in

	if (not (success1 && success2)) && !real then begin
		print_endline "Junk test failed!";
		failwith "Junk test failed!"
	end

let restart_master state =
	let master = List.hd state.vhdds in
	let oldpid = Int_client.Debug.get_pid master.intrpc in
	(try Int_client.Debug.die master.intrpc true with _ -> ());
	let rec wait_for_new_pid () =
		try
			Thread.delay 0.1;
			let newpid = Int_client.Debug.get_pid master.intrpc in
			if newpid = oldpid then wait_for_new_pid ()
		with _ ->
			wait_for_new_pid ()
	in wait_for_new_pid ();

	let rec wait_for_ready () =
		try
			Thread.delay 0.1;
			Int_client.Debug.get_ready master.intrpc
		with _ ->
			wait_for_ready ()
	in

	wait_for_ready ();

	let rec wait_for_attach_finished () =
		try
			Thread.delay 0.1;
			let attach_finished = Int_client.Debug.get_attach_finished master.intrpc state.sr.sr_uuid in
			if not attach_finished then wait_for_attach_finished ()
		with _ -> wait_for_attach_finished ()
	in

	wait_for_attach_finished ()


let master_set_wait_mode state wait =
	let master = List.hd state.vhdds in
	Int_client.Debug.waiting_mode_set master.intrpc wait

let master_step state =
	let master = List.hd state.vhdds in
	D.debug "Getting waiting locks";
	let locks = Int_client.Debug.waiting_locks_get master.intrpc in
	if List.length locks > 0 then begin
		let (lock,_) = List.hd locks in
		D.debug "Unwaiting lock";
		Int_client.Debug.waiting_lock_unwait master.intrpc lock;
		true
	end else (D.debug "No waiting locks"; Thread.delay 0.1; false)

let vdi_clone state vdi =
	let master = List.hd state.vhdds in
	let newvdi = SC.VDI.clone master.rpc state.gp (Some state.sr) [] vdi in
	let newvdi = {vdi_uuid=None;
	vdi_location=newvdi.vdi_location} in
	(newvdi,{state with vdis=newvdi::state.vdis})

let vdi_snapshot state vdi =
	let master = List.hd state.vhdds in
	let newvdi = SC.VDI.snapshot master.rpc state.gp (Some state.sr) [] vdi in
	let newvdi = {vdi_uuid=None;
	vdi_location=newvdi.vdi_location} in
	(newvdi,{state with vdis=newvdi::state.vdis})


(* ========================================================================================================= *)

(* Test cases:
 *
 *  1. Create VDI with some junk in it.
 *  2. Attach VDI on master/slave
 *  3. Maybe activate VDI
 *  4. Restart master
 *  5. Maybe activate VDI
 *  6. Check junk
 *  7. Deactivate/Detach
 *
 *)

module Master_restart_tests = struct
	let slave_attach_test state vdi junk =
		let master = List.hd state.vhdds in
		let slave = List.hd (List.tl state.vhdds) in
		attach_vdi state slave.host_id vdi true;
		restart_master state;
		let inconsistent = check_consistency state in
		activate_vdi state slave.host_id vdi;
		check_junk state slave.host_id vdi junk;
		deactivate_vdi state slave.host_id vdi;
		detach_vdi state slave.host_id vdi;
		assert_equal (List.length inconsistent) 0

	let slave_activate_test state vdi junk =
		let master = List.hd state.vhdds in
		let slave = List.hd (List.tl state.vhdds) in
		attach_vdi state slave.host_id vdi true;
		activate_vdi state slave.host_id vdi;
		restart_master state;
		let inconsistent = check_consistency state in
		check_junk state slave.host_id vdi junk;
		deactivate_vdi state slave.host_id vdi;
		detach_vdi state slave.host_id vdi;
		assert_equal (List.length inconsistent) 0

	let master_attach_test state vdi junk =
		let master = List.hd state.vhdds in
		attach_vdi state master.host_id vdi true;
		restart_master state;
		let inconsistent = check_consistency state in
		activate_vdi state master.host_id vdi;
		check_junk state master.host_id vdi junk;
		deactivate_vdi state master.host_id vdi;
		detach_vdi state master.host_id vdi;
		assert_equal (List.length inconsistent) 0

	let master_activate_test state vdi junk =
		let master = List.hd state.vhdds in
		attach_vdi state master.host_id vdi true;
		activate_vdi state master.host_id vdi;
		restart_master state;
		let inconsistent = check_consistency state in
		check_junk state master.host_id vdi junk;
		deactivate_vdi state master.host_id vdi;
		detach_vdi state master.host_id vdi;
		assert_equal (List.length inconsistent) 0

	let common f =
		let state = (!init) () in
		let master = List.hd state.vhdds in
		Pervasiveext.finally (fun () ->
			let size = stddisksize in
			let (vdi,state) = create_vdi state size false in
			attach_vdi state master.host_id vdi true;
			activate_vdi state master.host_id vdi;
			let junk = write_junk state master.host_id vdi smallerdisksize 10 [] in
			deactivate_vdi state master.host_id vdi;
			detach_vdi state master.host_id vdi;
			f state vdi junk)
			(fun () -> (!cleanup) state)

	let slave_attach = make_test_case "slave_attach"
		"Ensure that the attachment status of a VDI on a slave is preserved over master restart"
		begin fun () -> common slave_attach_test end

	let slave_activate = make_test_case "slave_activate"
		"Ensure that the activation status of a VDI on a slave is preserved over master restart"
		begin fun () -> common slave_activate_test end

	let master_attach = make_test_case "master_attach"
		"Ensure that the attachment status of a VDI on a master is preserved over master restart"
		begin fun () -> common master_attach_test end

	let master_activate = make_test_case "master_activate"
		"Ensure that the activation status of a VDI on a master is preserved over master restart"
		begin fun () -> common master_activate_test end

	let tests = make_module_test_suite "Master_restart"
		[master_attach; master_activate ]

	let tests2 = make_module_test_suite "Master_restart2"
		[slave_attach; slave_activate ]
end

(* ========================================================================================================= *)

(* Test cases:
 *
 *  1. Create VDI with some junk in it.
 *  2. Generate the config
 *  3. Detach the SR.
 *  4. Maybe attach the SR (master or slave)
 *  5. Attach from config (master or slave)
 *  6. Check for inconsistencies
 *  7. Check junk
 *  8. Deactivate/detach
 *
 *)

module Attach_from_config_tests = struct
	let master_sr_attached state master slave_opt vdi config junk =
		let xml = SC.VDI.attach_from_config master.rpc config in
		ignore(SC.expect_success (SC.methodResponse (Xml.parse_string xml)));
		let inconsistent = check_consistency state in
		check_junk state master.host_id vdi junk;
		deactivate_vdi state master.host_id vdi;
		detach_vdi state master.host_id vdi;
		if List.length inconsistent > 0
		then failwith "Inconsistency detected!"

	let slave_sr_attached state master slave_opt vdi config junk =
		let Some slave = slave_opt in
		let xml = SC.VDI.attach_from_config slave.rpc config in
		ignore(SC.expect_success (SC.methodResponse (Xml.parse_string xml)));
		let inconsistent = check_consistency state in
		check_junk state slave.host_id vdi junk;
		deactivate_vdi state slave.host_id vdi;
		detach_vdi state slave.host_id vdi;
		if List.length inconsistent > 0
		then failwith "Inconsistency detected!"

	let slave_sr_detached state master slave_opt vdi config junk =
		let Some slave = slave_opt in
		let master_gp = { state.gp with gp_device_config=("SRmaster","true")::state.gp.gp_device_config; } in
		SC.SR.detach slave.rpc state.gp (Some state.sr);
		let xml = SC.VDI.attach_from_config slave.rpc config in
		ignore(SC.expect_success (SC.methodResponse (Xml.parse_string xml)));
		SC.SR.attach slave.rpc state.gp (Some state.sr);
		let inconsistent = check_consistency state in
		check_junk state slave.host_id vdi junk;
		deactivate_vdi state slave.host_id vdi;
		detach_vdi state slave.host_id vdi;
		if List.length inconsistent > 0
		then failwith "Inconsistency detected!"

	let master_sr_detached state master slave_opt vdi config junk =
		let master_gp = { state.gp with gp_device_config=("SRmaster","true")::state.gp.gp_device_config; } in
		SC.SR.detach master.rpc state.gp (Some state.sr);
		let xml = SC.VDI.attach_from_config master.rpc config in
		ignore(SC.expect_success (SC.methodResponse (Xml.parse_string xml)));
		SC.SR.attach master.rpc master_gp (Some state.sr);
		Thread.delay 1.0;
		let inconsistent = check_consistency state in
		check_junk state master.host_id vdi junk;
		deactivate_vdi state master.host_id vdi;
		detach_vdi state master.host_id vdi;
		if List.length inconsistent > 0
		then failwith "Inconsistency detected!"

	let common f =
		let state = (!init) () in
		let master = List.hd state.vhdds in
		let slave = try Some (List.hd (List.tl state.vhdds)) with _ -> None in
		Pervasiveext.finally (fun () ->
			let size = stddisksize in
			let (vdi,state) = create_vdi state size true in
			attach_vdi state master.host_id vdi true;
			activate_vdi state master.host_id vdi;
			let junk = write_junk state master.host_id vdi smallerdisksize 10 [] in
			deactivate_vdi state master.host_id vdi;
			detach_vdi state master.host_id vdi;
			let config = SC.VDI.generate_config master.rpc state.gp (Some state.sr) vdi.vdi_location in
			f state master slave vdi config junk)
			(fun () -> (!cleanup) state)

	let master_sr_attached_tc = make_test_case "master_sr_attached"
		"Call VDI.attach_from_config on a master that has the SR already attached"
		begin fun () -> common master_sr_attached end

	let master_sr_detached_tc = make_test_case "master_sr_detached"
		"Call VDI.attach_from_config on a master that does not have the SR already attached"
		begin fun () -> common master_sr_detached end

	let slave_sr_attached_tc = make_test_case "slave_sr_attached"
		"Call VDI.attach_from_config on a slave that has the SR already attached"
		begin fun () -> common slave_sr_attached end

	let slave_sr_detached_tc =
		make_test_case "slave_sr_detached"
			"Call VDI.attach_from_config on a slave that does not have the SR already attached"
			begin fun () -> common slave_sr_detached end

	let tests = make_module_test_suite "Attach_from_config"
		[master_sr_attached_tc; master_sr_detached_tc]

	let tests2 = make_module_test_suite "Attach_from_config2"
		[slave_sr_attached_tc; slave_sr_detached_tc]

end



module Killed_operations = struct
	let get_keys state =
		let master = List.hd state.vhdds in
		let id_map = Int_client.Debug.get_id_to_leaf_map master.intrpc state.sr.sr_uuid in
		let vhds = Int_client.Debug.get_vhds master.intrpc state.sr.sr_uuid in
		let vhds = Vhd_records.get_vhd_hashtbl_copy dummy_context vhds in
		let container = Int_client.Debug.get_vhd_container master.intrpc state.sr.sr_uuid in
		let ids = Hashtbl.fold (fun k v acc -> k::acc) id_map [] in
		let vhds = Hashtbl.fold (fun k v acc -> k::acc) vhds [] in
		let lvs = match container with
			| Lvmabs_types.VolumeGroup vg -> List.map (fun lv -> lv.Lvm.Lv.name) vg.Lvm.Vg.lvs
			| Lvmabs_types.OrigLVMVG vg -> List.map Olvm.get_lv_name (Olvm.get_lvs vg)
		in
		(ids,vhds,lvs)

	let compare_keys (ids1,vhds1,lvs1) (ids2,vhds2,lvs2) =
		let sd = List.set_difference in
		(sd ids1 ids2, sd ids2 ids1,
		sd vhds1 vhds2, sd vhds2 vhds1,
		sd lvs1 lvs2, sd lvs2 lvs1)

	let print_compared_keys (a, b, c, d, e, f) =
		let print name list =
			print_endline (Printf.sprintf "%s: [%s]" name (String.concat "; " list))
		in
		print "ids1 \ ids2" a;
		print "ids2 \ ids1" b;
		print "vhds1 \ vhds2" c;
		print "vhds2 \ vhds1" d;
		print "lvs1 \ lvs2" e;
		print "lvs2 \ lvs1" f

	let clone_test (a,b,c,d,e,f) =
		let t0 l = List.length l = 0 in
		let t1 l = List.length l = 1 in
		let l l = List.length l in
		let ok = t0 a && t0 c && t0 e &&
			((t0 b && t0 d && t0 f) || (t1 b && t1 d && t1 f)) in
		if not ok then (print_endline (Printf.sprintf "clone_test: a=%d b=%d c=%d d=%d e=%d f=%d"
			(l a) (l b) (l c) (l d) (l e) (l f)); exit 1; failwith "Error!")

	let clone_innertest (vdi,state,junk) =
		let host = if List.length state.vhdds > 1 then List.hd (List.tl state.vhdds) else List.hd state.vhdds in
		check_junk state host.host_id vdi junk

	let clone_setup state =
		let (vdi,state) = create_vdi state stddisksize false in
		let host = if List.length state.vhdds > 1 then List.hd (List.tl state.vhdds) else List.hd state.vhdds in
		let slave = List.hd (List.tl state.vhdds) in
		attach_vdi state host.host_id vdi true;
		activate_vdi state host.host_id vdi;
		let junk = write_junk state host.host_id vdi smallerdisksize 10 [] in
		(vdi,state, junk)

	let clone_clean (vdi,state,_) =
		let host = if List.length state.vhdds > 1 then List.hd (List.tl state.vhdds) else List.hd state.vhdds in
		deactivate_vdi state host.host_id vdi;
		detach_vdi state host.host_id vdi;
		delete_vdi state vdi

	let clone_op (vdi,state,_) id =
		let master = List.hd state.vhdds in
		(SC.VDI.clone (master.rpc ~task_id:id) state.gp (Some state.sr) [] vdi.vdi_location).vdi_location

	let leaf_coalesce_innertest (vdi,state,junk) =
		let host = if List.length state.vhdds > 1 then List.hd (List.tl state.vhdds) else List.hd state.vhdds in
		check_junk state host.host_id vdi junk

	let leaf_coalesce_test (a,b,c,d,e,f) =
		let t0 l = List.length l = 0 in
		let t1 l = List.length l = 1 in
		let l l = List.length l in
		let ok = (t0 a && t0 b) && ((t0 c && t0 e) || (t1 c && t1 e)) &&
			((t0 d && t0 f) || (t1 d && t1 f)) in
		if not ok then (print_endline (Printf.sprintf
			"leaf_coalesce_test: a=%d b=%d c=%d d=%d e=%d f=%d"
			(l a) (l b) (l c) (l d) (l e) (l f)); exit 1; failwith "Error!")

	let leaf_coalesce_setup state =
		let master = List.hd state.vhdds in
		let host = if List.length state.vhdds > 1 then List.hd (List.tl state.vhdds) else List.hd state.vhdds in
		let (vdi,state) = create_vdi state stddisksize false in
		attach_vdi state host.host_id vdi true;
		activate_vdi state host.host_id vdi;
		let junk = write_junk state host.host_id vdi smallerdisksize 10 [] in
		let (vdi2,state) = vdi_clone state vdi.vdi_location in
		let junk2 = write_junk state host.host_id vdi smallerdisksize 10 junk in
		let state = delete_vdi state vdi2 in
		(vdi,state,junk2)

	let leaf_coalesce_clean (vdi,state,_) =
		let host = if List.length state.vhdds > 1 then List.hd (List.tl state.vhdds) else List.hd state.vhdds in
		deactivate_vdi state host.host_id vdi;
		detach_vdi state host.host_id vdi;
		delete_vdi state vdi

	let leaf_coalesce_op (vdi,state,_) id =
		let master = List.hd state.vhdds in
		SC.SR.scan (master.rpc ~task_id:id) state.gp (Some state.sr)

	let coalesce_innertest (vdi,vdi3,state,junk) =
		let host = if List.length state.vhdds > 1 then List.hd (List.tl state.vhdds) else List.hd state.vhdds in
		check_junk state host.host_id vdi junk

	let coalesce_test (a,b,c,d,e,f) =
		let t0 l = List.length l = 0 in
		let t1 l = List.length l = 1 in
		let l l = List.length l in
		let ok = (t0 a && t0 b) && ((t0 c && t0 e) || (t1 c && t1 e)) &&
			((t0 d && t0 f) || (t1 d && t1 f)) in
		if not ok then (print_endline (Printf.sprintf "leaf_coalesce_test: a=%d b=%d c=%d d=%d e=%d f=%d"
			(l a) (l b) (l c) (l d) (l e) (l f)); failwith "Error!")

	let coalesce_setup state =
		let master = List.hd state.vhdds in
		let host = if List.length state.vhdds > 1 then List.hd (List.tl state.vhdds) else List.hd state.vhdds in
		let (vdi,state) = create_vdi state stddisksize false in
		attach_vdi state host.host_id vdi true;
		activate_vdi state host.host_id vdi;
		let junk = write_junk state host.host_id vdi smallerdisksize 10 [] in
		let (vdi2,state) = vdi_clone state vdi.vdi_location in
		let junk2 = write_junk state host.host_id vdi smallerdisksize 10 junk in
		let (vdi3,state) = vdi_clone state vdi.vdi_location in
		let junk3 = write_junk state host.host_id vdi smallerdisksize 10 junk2 in
		let state = delete_vdi state vdi2 in
		(vdi,vdi3,state,junk3)

	let coalesce_clean (vdi,vdi3,state,_) =
		let host = if List.length state.vhdds > 1 then List.hd (List.tl state.vhdds) else List.hd state.vhdds in
		deactivate_vdi state host.host_id vdi;
		detach_vdi state host.host_id vdi;
		delete_vdi state vdi;
		delete_vdi state vdi3

	let coalesce_op (vdi,vdi3,state,_) id =
		let master = List.hd state.vhdds in
		SC.SR.scan (master.rpc ~task_id:id) state.gp (Some state.sr)

	let get_op_n state master setup clean f name =
		let result = setup state in
		master_set_wait_mode state true;
		let opn = Lockingtest.measure_call master.intrpc (f result) ignore name in
		master_set_wait_mode state false;
		clean result;
		opn

	let get_clonen state master =
		get_op_n state master clone_setup clone_clean clone_op "clone"

	let get_leaf_coalescen state master =
		get_op_n state master leaf_coalesce_setup leaf_coalesce_clean leaf_coalesce_op "leaf_coalesce"

	let get_coalescen state master =
		get_op_n state master coalesce_setup coalesce_clean coalesce_op "coalesce"

	let kill_after_op_n state master setup clean op name innertest test n =
		master_set_wait_mode state false;
		let s : string = SC.SR.scan master.rpc state.gp (Some state.sr) in
		let keys1 = get_keys state in
		let result = setup state in
		Pervasiveext.finally (fun () ->
			master_set_wait_mode state true;
			let finished = ref false in
			Thread.create (fun () -> try ignore(op result name); finished := true with _ -> ()) ();
			let rec inner i =
				let rec get_lock time =
					if time>600.0 then failwith "Waited too long";
					if !finished then failwith "Unexpectedly finished!";
					let locks = Int_client.Debug.waiting_locks_get master.intrpc in
					if List.length locks = 0
					then (Thread.delay 0.1; get_lock (time +. 0.1))
					else (List.hd locks)
				in
				let lock = get_lock 0.0 in
				Int_client.Debug.waiting_lock_unwait master.intrpc (fst lock);
				if i=n then begin
					get_lock 0.0; (* Wait for the op to complete *)
					print_endline (Printf.sprintf "Killing after op %d (%s: %s)" n
						(snd lock).Int_types.lc_lock_required (snd lock).Int_types.lc_reason);
					restart_master state
				end else inner (i+1)
			in
			inner 0;

			let inconsistent = check_consistency state in
			innertest result;
			if List.length inconsistent > 0
			then begin
				print_endline (Printf.sprintf "Inconsistency detected after step %d!" n);
				failwith "Inconsistent!"
			end)
			(fun () ->
				master_set_wait_mode state false;
				clean result);

		ignore(SC.SR.scan (master.rpc) state.gp (Some state.sr));
		let keys2 = get_keys state in
		let comp = compare_keys keys1 keys2 in
		test comp

	let get_tests () =
		let state = (!init) () in
		let master = List.hd state.vhdds in
		let clonen = get_clonen state master in
		let leafcoalescen = get_leaf_coalescen state master in
		let coalescen = get_coalescen state master in
		(!cleanup) state;
		let rec testn setup clean op innertest test name max n =
			if n=max-1
			then []
			else (make_test_case (Printf.sprintf "killed_%s_after_op_%d" name n)
				(Printf.sprintf "Ensure that an interrupted %s does not leave junk" name)
				begin fun () ->
					let state = (!init) () in
					let master = List.hd state.vhdds in
					Pervasiveext.finally (fun () ->
						kill_after_op_n state master setup clean op name innertest test n)
						(fun () -> (!cleanup) state)
				end)::(testn setup clean op innertest test name max (n+1))
		in

		make_module_test_suite "Interrupted_ops"
			((testn clone_setup clone_clean clone_op clone_innertest clone_test "clone" clonen 0) @
			 (testn leaf_coalesce_setup leaf_coalesce_clean leaf_coalesce_op leaf_coalesce_innertest leaf_coalesce_test "leaf_coalesce" leafcoalescen 0) @
			 (testn coalesce_setup coalesce_clean coalesce_op coalesce_innertest coalesce_test "coalesce" coalescen 0))
end

module Basic_tests = struct
	let sr_probe =
		make_test_case "sr_probe"
			"Check that a probe of a detached SR can locate the SR"
			begin fun () ->
				let state = (!init) () in
				Pervasiveext.finally (fun () -> 
					let master = List.hd state.vhdds in
					SC.SR.detach master.rpc state.gp (Some state.sr);
					let probe_results = SC.SR.probe master.rpc state.gp [] in
					let xml = Xml.parse_string probe_results in
					(match xml with
						| Xml.Element("SRlist",[],elts) ->
							if not (List.exists (fun elt -> match elt with Xml.Element("SR",[],[Xml.Element("UUID",[],[Xml.PCData uuid])]) -> state.sr.sr_uuid = uuid | _ -> false) elts) then failwith "Can't find SR!"
						| _ -> failwith "Bad XML returned");
					SC.SR.attach master.rpc {state.gp with gp_device_config=("SRmaster","true")::state.gp.gp_device_config} (Some state.sr);
					Thread.delay 1.0)
					(fun () -> (!cleanup) state)
			end

	let sr_delete =
		make_test_case "sr_delete"
			"Check that a sr can be deleted"
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				SC.SR.delete master.rpc state.gp (Some state.sr);				
				!(cleanup) state
			end

	let sr_scan =
		make_test_case "sr_scan"
			"Check that a scan returns successfully"
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				SC.SR.scan master.rpc state.gp (Some state.sr);
				!(cleanup) state
			end

	let sr_update =
		make_test_case "sr_update"
			"Check that an SR update returns successfully"
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				SC.SR.update master.rpc state.gp (Some state.sr);
				!(cleanup) state
			end

	let vdi_create_raw =
		make_test_case "vdi_create_raw"
			"Check that we can create raw VDIs"
			begin fun () ->
				let state = (!init) () in
				try 
					let master = List.hd state.vhdds in
					let size = stddisksize in
					let (vdi,state) = create_vdi state size true in
					attach_vdi state master.host_id vdi true;
					activate_vdi state master.host_id vdi;
					deactivate_vdi state master.host_id vdi;
					detach_vdi state master.host_id vdi;
					!(cleanup) state
				with e -> 
					!cleanup state;
					raise e
			end

	let vdi_raw_attach_rw_multiple =
		make_test_case "vdi_create_raw_attach_rw_multiple"
			"Check that we can create raw VDIs and attach them to multiple hosts"
			begin fun () ->
				let state = (!init) () in
				try
					let master = List.hd state.vhdds in
					let slave = List.hd (List.tl state.vhdds) in
					let size = stddisksize in
					let (vdi,state) = create_vdi state size true in
					attach_vdi state master.host_id vdi true;
					activate_vdi state master.host_id vdi;
					attach_vdi state slave.host_id vdi true;
					activate_vdi state slave.host_id vdi;
					let junk = write_junk state master.host_id vdi smallerdisksize 10 [] in
					check_junk state slave.host_id vdi junk;
					deactivate_vdi state slave.host_id vdi;
					detach_vdi state slave.host_id vdi;
					deactivate_vdi state master.host_id vdi;
					detach_vdi state master.host_id vdi;
					!(cleanup) state
				with e -> 
					!(cleanup) state;
					raise e
			end

	let vdi_attach =
		make_test_case "vdi_attach"
			"Check that a VDI can be successfully attached"
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				let size = stddisksize in
				let (vdi,state) = create_vdi state size false in
				attach_vdi state master.host_id vdi true;
				detach_vdi state master.host_id vdi;
				!(cleanup) state
			end

	let vdi_activate =
		make_test_case "vdi_activate"
			"Check that a VDI can be successfully activated"
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				let size = stddisksize in
				let (vdi,state) = create_vdi state size false in
				attach_vdi state master.host_id vdi true;
				activate_vdi state master.host_id vdi;
				deactivate_vdi state master.host_id vdi;
				detach_vdi state master.host_id vdi;
				!(cleanup) state
			end

	let vdi_double_attach =
		make_test_case "vdi_double_attach"
			"Check that VDI double attaching is OK"
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				let slave = List.hd (List.tl state.vhdds) in
				let size = stddisksize in
				let (vdi,state) = create_vdi state size false in
				attach_vdi state master.host_id vdi true;
				attach_vdi state slave.host_id vdi true;
				detach_vdi state master.host_id vdi;
				detach_vdi state slave.host_id vdi;
				!(cleanup) state
			end

	let vdi_double_attach_with_activate =
		make_test_case "vdi_double_attach_with_activate"
			"Check that when a VDI is doubly attached, it can be activated in either place"
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				let slave = List.hd (List.tl state.vhdds) in
				let size = stddisksize in
				let (vdi,state) = create_vdi state size false in
				attach_vdi state master.host_id vdi true;
				attach_vdi state slave.host_id vdi true;
				activate_vdi state master.host_id vdi;
				deactivate_vdi state master.host_id vdi;
				activate_vdi state slave.host_id vdi;
				deactivate_vdi state slave.host_id vdi;
				detach_vdi state master.host_id vdi;
				detach_vdi state slave.host_id vdi;
				!(cleanup) state
			end

	let vdi_double_attach_ro_with_double_activate =
		make_test_case "vdi_double_attach_ro_with_double_activate"
			"Check that when a VDI is doubly attached, it can be activated in either place"
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				let slave = List.hd (List.tl state.vhdds) in
				let size = stddisksize in
				let (vdi,state) = create_vdi state size false in
				attach_vdi state master.host_id vdi false;
				attach_vdi state slave.host_id vdi false;
				activate_vdi state master.host_id vdi;
				activate_vdi state slave.host_id vdi;
				deactivate_vdi state slave.host_id vdi;
				deactivate_vdi state master.host_id vdi;
				detach_vdi state master.host_id vdi;
				detach_vdi state slave.host_id vdi;
				!(cleanup) state
			end

	let vdi_no_double_activate =
		make_test_case "vdi_no_double_activate"
			"Check that when a VDI cannot be double activated"
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				let slave = List.hd (List.tl state.vhdds) in
				let size = stddisksize in
				let (vdi,state) = create_vdi state size false in
				attach_vdi state master.host_id vdi true;
				attach_vdi state slave.host_id vdi true;
				activate_vdi state master.host_id vdi;
				let success =
					try
						activate_vdi state slave.host_id vdi;
						deactivate_vdi state slave.host_id vdi;
						false;
					with  _ ->
						true
				in
				(if not success then failwith "Double activation not prevented");
				deactivate_vdi state master.host_id vdi;
				detach_vdi state master.host_id vdi;
				detach_vdi state slave.host_id vdi;
				!(cleanup) state
			end

	let vdi_update =
		make_test_case "vdi_update"
			"Check that a VDI can be successfully updated"
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				let (vdi,state) = create_vdi state stddisksize false in
				SC.VDI.update master.rpc state.gp (Some state.sr) vdi.vdi_location;
				!(cleanup) state
			end


	let vdi_delete =
		make_test_case "vdi_delete"
			"Check that a VDI can be successfully deleted"
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				let size = stddisksize in
				let (vdi,state) = create_vdi state size false in
				attach_vdi state master.host_id vdi true;
				detach_vdi state master.host_id vdi;
				let state = delete_vdi state vdi in
				!(cleanup) state
			end

	let vdi_clone_snapshot_tests online is_snapshot () =
		let state = (!init) () in
		let master = List.hd state.vhdds in
		let size = stddisksize in
		let (vdi,state) = create_vdi state size false in
		attach_vdi state master.host_id vdi true;
		activate_vdi state master.host_id vdi;
		let junk = write_junk state master.host_id vdi smallerdisksize 10 [] in
		if not online then begin
			deactivate_vdi state master.host_id vdi;
			detach_vdi state master.host_id vdi;
		end;
		let (vdi2,state) = (if is_snapshot then vdi_snapshot else vdi_clone) state vdi.vdi_location in

		(* Check original *)
		if not online then begin
			attach_vdi state master.host_id vdi true;
			activate_vdi state master.host_id vdi;
		end;
		check_junk state master.host_id vdi junk;
		deactivate_vdi state master.host_id vdi;
		detach_vdi state master.host_id vdi;

		(* Check snapshot *)
		attach_vdi state master.host_id vdi2 true;
		activate_vdi state master.host_id vdi2;
		check_junk state master.host_id vdi2 junk;
		deactivate_vdi state master.host_id vdi2;
		detach_vdi state master.host_id vdi2;

		let state = delete_vdi state vdi2 in
		let state = delete_vdi state vdi in
		!cleanup state

	let vdi_snapshot_online =
		make_test_case "vdi_snapshot_online"
			"Check that a VDI can be snapshotted while attached"
			(vdi_clone_snapshot_tests true true)

	let vdi_snapshot_offline =
		make_test_case "vdi_snapshot_offline"
			"Check that a VDI can be snapshotted while not attached"
			(vdi_clone_snapshot_tests false true)

	let vdi_clone_online =
		make_test_case "vdi_clone_online"
			"Check that a VDI can be cloned while attached"
			(vdi_clone_snapshot_tests true false)

	let vdi_clone_offline =
		make_test_case "vdi_clone_offline"
			"Check that a VDI can be cloned while not attached"
			(vdi_clone_snapshot_tests false false)

	let vdi_resize_bigger_smaller resize_to_larger_size online () =
		let state = (!init) () in
		let master = List.hd state.vhdds in
		let (size,newsize) =
			if resize_to_larger_size
			then (smallerdisksize,stddisksize)
			else (stddisksize,smallerdisksize)
		in
		let (vdi,state) = create_vdi state size false in
		attach_vdi state master.host_id vdi true;
		activate_vdi state master.host_id vdi;
		let _ = write_junk state master.host_id vdi size 10 [] in
		let junk = write_junk state master.host_id vdi smallerdisksize 10 [] in
		if not online then begin
			deactivate_vdi state master.host_id vdi;
			detach_vdi state master.host_id vdi
		end;
		let state = (if online then resize_vdi_online else resize_vdi) state vdi newsize in
		if not online then begin
			attach_vdi state master.host_id vdi true;
			activate_vdi state master.host_id vdi;
		end;
		let junk = check_junk state master.host_id vdi junk in
		deactivate_vdi state master.host_id vdi;
		detach_vdi state master.host_id vdi;
		let state = delete_vdi state vdi in
		!cleanup state

	let vdi_resize_smaller =
		make_test_case "vdi_resize_smaller"
			"Check that a VDI can be resized to a smaller size"
			(vdi_resize_bigger_smaller false false)

	let vdi_resize_larger =
		make_test_case "vdi_resize_larger"
			"Check that a VDI can be resized to a larger size"
			(vdi_resize_bigger_smaller true false)

	let vdi_resize_smaller_online =
		make_test_case "vdi_resize_smaller_online"
			"Check that a VDI can be resized to a smaller size"
			(vdi_resize_bigger_smaller false true)

	let vdi_resize_larger_online =
		make_test_case "vdi_resize_larger_online"
			"Check that a VDI can be resized to a larger size"
			(vdi_resize_bigger_smaller true true)


	let tests =
		make_module_test_suite "Basic_tests"
			[sr_probe; sr_delete; sr_scan; sr_update; vdi_update; vdi_attach; vdi_activate;
			vdi_snapshot_online; vdi_create_raw;
			vdi_snapshot_offline; vdi_clone_online; vdi_clone_offline; (*vdi_resize_smaller;*) vdi_resize_larger;
			(*vdi_resize_smaller_online;*) vdi_resize_larger_online]

	let tests2 =
		make_module_test_suite "Basic_tests2"
			[vdi_double_attach; vdi_double_attach_with_activate; vdi_no_double_activate;
			vdi_double_attach_ro_with_double_activate; vdi_raw_attach_rw_multiple]
end



module Parallel_tests = struct

	let leaves = ref []
	let lock = Mutex.create ()

	let meg = Int64.mul 1024L 1024L

	exception No_vdis

	let get_random_vdi () =
		Mutex.execute lock (fun () ->
			let n = List.length !leaves in
			if n=0 then raise No_vdis;
			let m = Random.int n in
			let vdi = List.nth !leaves m in
			vdi)

	let remove_random_vdi () =
		Mutex.execute lock (fun () ->
			let n = List.length !leaves in
			let m = Random.int n in
			let vdi = List.nth !leaves m in
			leaves := List.filter (fun vdi' -> vdi <> vdi') !leaves;
			vdi)

	let do_op state host_id is_master =
		let vhdd = List.find (fun vhdd -> vhdd.host_id = host_id) state.vhdds in
		let rpc = vhdd.rpc in
		let gp = state.gp in
		let sr = state.sr in
		let intrpc = vhdd.intrpc in
		match Random.int (if is_master then 6 else 2) with
			| 0 -> (* Attach/activate disk *)
				let vdi = remove_random_vdi () in
				Pervasiveext.finally
					(fun () ->
						debug "VDI.activate/attach (%s)" vdi;
						let path = SC.VDI.attach rpc gp (Some sr) vdi in
						ignore(SC.VDI.activate rpc gp (Some sr) vdi);
						ignore(Int_client.Debug.write_junk intrpc sr.sr_uuid vdi (Int64.mul meg 1L) 3 []);
						(*					ignore(Util.write_junk path (Int64.mul meg 1L) 3 [] None);*)
						Thread.delay 1.0)
					(fun () ->
						Mutex.execute lock (fun () ->
							leaves := vdi :: !leaves)) (* add it back in *)
			| 1 -> (* Detach/deactivate disk *)
				let vdi = get_random_vdi () in
				debug "VDI.deactivate/detach (%s)" vdi;
				(try ignore(SC.VDI.deactivate rpc gp (Some sr) vdi) with _ -> ());
				(try ignore(SC.VDI.detach rpc gp (Some sr) vdi) with _ -> ())
			| 2 -> (* Create disk *)
				debug "VDI.create";
				let vdi = (SC.VDI.create rpc gp (Some sr) [] (Int64.mul meg 50L)).vdi_location in
				Mutex.execute lock (fun () ->
					leaves := vdi :: !leaves)
			| 3 -> (* Delete disk *)
				let vdi = get_random_vdi () in
				debug "VDI.delete (%s)" vdi;
				ignore(SC.VDI.delete rpc gp (Some sr) vdi);
				Mutex.execute lock (fun () ->
					leaves := List.filter (fun vdi' -> vdi' <> vdi) !leaves)
			| 4 -> (* Clone disk *)
				let vdi = get_random_vdi () in
				debug "VDI.clone (%s)" vdi;
				let vdi2 = (SC.VDI.clone rpc gp (Some sr) [] vdi).vdi_location in
				Mutex.execute lock (fun () ->
					leaves := vdi2 :: !leaves);
			| 5 -> (* Scan *)
				debug "SR.scan";
				ignore(SC.SR.scan rpc gp (Some sr))
			| _ -> failwith "Undefined operation!"

	let operation_thread state host_id is_master rd wr2 () =
		debug "Thread started";
		while true do
			try
				let (ready,_,_) = Unix.select [rd] [] [] 0.0 in
				if ready=[] then begin
					do_op state host_id is_master
				end else begin
					let str = Unixext.really_read_string rd 2 in
					if str = "OK" then begin
						debug "Received exit message";
						ignore(Unix.write wr2 "OK" 0 2);
						Thread.exit ()
					end else begin
						debug "Received odd message: %s" str;
					end
				end
			with
				|No_vdis ->
					debug "Waiting for some VDIs to turn up";
					Thread.delay 1.0
				| e ->
					debug "Caught exception: %s" (SC.e_to_string e);
					debug "Pausing for 1 seconds";
					Thread.delay 1.0
		done

	let paralleltest state =
		let n = 10 in
		let gp = state.gp in
		let sr = Some state.sr in

		let rec do_host channels (host_id, is_master) =
			let rec start_thread channels m =
				if m=0 then channels else begin
					let (rd,wr) = Unix.pipe () in
					let (rd2,wr2) = Unix.pipe () in

					ignore(Thread.create (operation_thread state host_id is_master rd wr2) ());

					start_thread ((rd2,wr)::channels) (m-1)
				end
			in start_thread channels n
		in

		let master_channel = do_host [] ((List.hd state.vhdds).host_id,true) in
		let channels = List.fold_left (fun channels vhdd -> do_host channels (vhdd.host_id,false)) master_channel (List.tl state.vhdds) in

		debug "Delaying for 60 seconds (%d threads spawned)" (List.length channels);

		Thread.delay 60.0;

		let response = String.create 2 in

		List.iter (fun (rd2,wr) ->
			ignore(Unix.write wr "OK" 0 2);
		) channels;

		List.iter (fun (rd2,wr) ->
			ignore(Unix.read rd2 response 0 2);
			assert(response="OK")
		) channels;

		debug "Finished. Cleaning up.";

		List.iter (fun vhdd ->
			List.iter (fun vdi ->
				let rpc = vhdd.rpc in
				debug "Deactivating on %s vdi %s" vhdd.host_id vdi;
				(try SC.VDI.deactivate rpc gp sr vdi with _ -> ());
				debug "Detaching on %s vdi %s" vhdd.host_id vdi;
				(try SC.VDI.detach rpc gp sr vdi with _ -> ());
				debug "Done"
			) !leaves) state.vhdds;

		let master = List.hd state.vhdds in
		let rpc = master.rpc in

		List.iter (fun vdi ->
			debug "Deleting VDI %s" vdi;
			(try SC.VDI.delete rpc gp sr vdi with _ -> ())) !leaves;

		(try ignore(SC.SR.scan rpc gp sr) with _ -> ());

		debug "Done"

	let parallel_test = make_test_case
		"parallel"
		"Do a lot of operations in parallel"
		begin fun () ->
			let state = (!init) () in
			paralleltest state;
			(!cleanup) state
		end
end

module Coalesce_tests = struct

	let check_thread state master vdi junk with_furious_attach_detach rd wr2 () =
		let fail = ref false in
		let primary = List.hd state.vhdds in
		let secondary = try List.hd (List.tl state.vhdds) with _ -> primary in
		if with_furious_attach_detach
		then begin
			deactivate_vdi state primary.host_id vdi;
			detach_vdi state primary.host_id vdi;
		end;

		let rec inner use_primary nchecks =
			let (ready,_,_) = Unix.select [rd] [] [] 0.0 in
			begin
				if ready = [] && (not !fail)
				then begin
					try

						if with_furious_attach_detach
						then begin
							print_endline "Attaching/Activating";
							attach_vdi state (if use_primary then primary else secondary).host_id vdi true;
							activate_vdi state (if use_primary then primary else secondary).host_id vdi;
							print_endline "Done";
						end;
							
						Pervasiveext.finally (fun () -> 
							check_junk state (if use_primary then primary else secondary).host_id vdi junk)
							(fun () -> 
								if with_furious_attach_detach
								then begin
									print_endline "Detaching/Deactivating";
									deactivate_vdi state (if use_primary then primary else secondary).host_id vdi;
									detach_vdi state (if use_primary then primary else secondary).host_id vdi;
									print_endline "Done";
								end)

					with _ ->
						fail := true
				end else begin
					print_endline (Printf.sprintf "Total number of checks: %d" nchecks);
					if Unixext.really_read_string rd 2 = "OK" then begin
						ignore(Unix.write wr2 (if !fail then "FA" else "OK") 0 2);
						Thread.exit ()
					end
				end
			end;
			inner (not use_primary) (nchecks+1)
		in inner true 0

	let leaf_coalesce with_furious_attach_detach rawbase = 
		make_test_case 
			(Printf.sprintf "%sleaf_coalesce%s" (if with_furious_attach_detach then "furious_" else "") (if rawbase then "_raw" else ""))
			(Printf.sprintf "Check that leaf coalesce does not cause data corruption%s"
				(if with_furious_attach_detach then " with furious attach and detach" else ""))
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				let size = stddisksize in
				let (vdi,state) = create_vdi state size rawbase in
				let path = attach_vdi state master.host_id vdi true in
				activate_vdi state master.host_id vdi;
				let junk = write_junk state master.host_id vdi smallerdisksize 10 [] in
				let (vdi2,state) = vdi_clone state vdi.vdi_location in
				let junk = write_junk state master.host_id vdi smallerdisksize 10 junk in

				(* Pipes to communicate with the check thread *)
				let (rd,wr) = Unix.pipe () in
				let (rd2,wr2) = Unix.pipe () in

				assert(get_chain_length state vdi.vdi_location = 2);
				ignore(Thread.create (check_thread state master vdi junk with_furious_attach_detach rd wr2) ());
				
				let state = delete_vdi state vdi2 in
				SC.SR.scan master.rpc state.gp (Some state.sr);
				
				assert(get_chain_length state vdi.vdi_location = 1);
				let response = String.create 2 in
				debug "Closing check thread\n%!";
				ignore(Unix.write wr "OK" 0 2);
				debug "Waiting for response\n%!";
				ignore(Unix.read rd2 response 0 2);
				debug "Done: response=%s\n%!" response;

(*				deactivate_vdi state master.host_id vdi;
				detach_vdi state master.host_id vdi;*)

				!(cleanup) state;

				if response="FA" then failwith "Junk checking failed somewhere!"
			end
				

	let coalesce with_furious_attach_detach rawbase =
		make_test_case
			(Printf.sprintf "%scoalesce%s" (if with_furious_attach_detach then "furious_" else "") (if rawbase then "_raw" else ""))
			(Printf.sprintf "Check that coalesce does not cause data corruption%s"
				(if with_furious_attach_detach then " with furious attach and detach" else ""))
			begin fun () ->
				let state = (!init) () in
				let master = List.hd state.vhdds in
				let size = stddisksize in
				let (vdi,state) = create_vdi state size rawbase in
				attach_vdi state master.host_id vdi true;
				activate_vdi state master.host_id vdi;
				let rec clone_and_write_junk n state current_junk vdis =
					let junk = write_junk state master.host_id vdi smallerdisksize 10 current_junk in
					let (vdi2,state) = vdi_clone state vdi.vdi_location in
					if n=10
					then (state,junk,vdi2::vdis)
					else clone_and_write_junk (n+1) state junk (vdi2::vdis)
				in
				let (state,junk,vdis) = clone_and_write_junk 0 state [] [] in

				(* To prevent leaf coalesce, add another clone here *)
				let (vdi2,state) = vdi_clone state vdi.vdi_location in

				print_endline (Printf.sprintf "Chain length: %d" (get_chain_length state vdi.vdi_location));

				(* Pipes to communicate with the check thread *)
				let (rd,wr) = Unix.pipe () in
				let (rd2,wr2) = Unix.pipe () in

				ignore(Thread.create (check_thread state master vdi junk with_furious_attach_detach rd wr2) ());



				let rec delete_vdis state vdis =
					match vdis with
						| condemned_vdi::vdis ->
							let state = delete_vdi state condemned_vdi in
							SC.SR.scan master.rpc state.gp (Some state.sr);
							print_endline (Printf.sprintf "Chain length: %d" (get_chain_length state vdi.vdi_location));
							delete_vdis state vdis
						| [] -> state
				in

				let state = delete_vdis state vdis in

				print_endline (Printf.sprintf "Chain length: %d" (get_chain_length state vdi.vdi_location));

				let response = String.create 2 in
				debug "Closing check thread\n%!";
				ignore(Unix.write wr "OK" 0 2);
				debug "Waiting for response\n%!";
				ignore(Unix.read rd2 response 0 2);
				debug "Done: response=%s\n%!" response;

				(*deactivate_vdi state master.host_id vdi;
				detach_vdi state master.host_id vdi;*)

				!(cleanup) state;

				if response="FA" then failwith "Junk checking failed somewhere!"
			end

	let offline_coalesce rawbase =
		make_test_case (Printf.sprintf "offline_coalesce%s" (if rawbase then "_raw" else ""))
			"Check that coalesce does not cause data corruption when performed offline"
			begin fun () ->
				debug "Starting offline coalesce";
				let state = (!init) () in
				let master = List.hd state.vhdds in
				let size = stddisksize in
				let (vdi,state) = create_vdi state size rawbase in
				attach_vdi state master.host_id vdi true;
				activate_vdi state master.host_id vdi;
				let rec clone_and_write_junk n state current_junk vdis =
					let junk = write_junk state master.host_id vdi smallerdisksize 10 current_junk in
					let (vdi2,state) = vdi_clone state vdi.vdi_location in
					if n=10
					then (state,junk,vdi2::vdis)
					else clone_and_write_junk (n+1) state junk (vdi2::vdis)
				in
				let (state,junk,vdis) = clone_and_write_junk 0 state [] [] in

				(* To prevent leaf coalesce, add another clone here *)
				let (vdi2,state) = vdi_clone state vdi.vdi_location in

				print_endline (Printf.sprintf "Chain length: %d" (get_chain_length state vdi.vdi_location));

				deactivate_vdi state master.host_id vdi;
				detach_vdi state master.host_id vdi;

				let rec delete_vdis state vdis =
					match vdis with
						| condemned_vdi::vdis ->
							let state = delete_vdi state condemned_vdi in
							SC.SR.scan master.rpc state.gp (Some state.sr);
							print_endline (Printf.sprintf "Chain length: %d" (get_chain_length state vdi.vdi_location));
							delete_vdis state vdis
						| [] -> state
				in

				let state = delete_vdis state vdis in

				attach_vdi state master.host_id vdi true;
				activate_vdi state master.host_id vdi;

				print_endline (Printf.sprintf "Chain length: %d" (get_chain_length state vdi.vdi_location));

				Pervasiveext.finally (fun () -> 
					check_junk state master.host_id vdi junk)
					(fun () -> !cleanup state)

			end


	let tests = make_module_test_suite "Coalesce"
		[offline_coalesce false; offline_coalesce true; coalesce true false; coalesce true true; coalesce false false; coalesce false true; leaf_coalesce true false; leaf_coalesce true true; leaf_coalesce false true; leaf_coalesce false false ]

end


let _ =
	Global.unsafe_mode := true;

	let target = ref "lork.uk.xensource.com" in
	let targetiqn = ref "iqn.2006-01.com.openfiler:jludlam1" in
	let scsiid = ref "14f504e46494c45006374504750302d4b3541312d36335743" in
	let hosts = ref "h01,h13" in
	let device = ref "/dev/sda3" in
	let local = ref false in
	let ext = ref false in
	let name = ref None in
	let list_mode = ref false in
	let server=ref "" in
	let serverpath=ref "" in
	let backend =ref "lvmnew" in
	let localpath = ref "/tmp/" in

	Arg.parse [
		"-r", Arg.Set real, "Real mode (default is dummy)";
		"-b", Arg.Set_string backend, "Set the backend (lvm, lvmnew, lvmoiscsi, lvmnewiscsi, ext, nfs)";
		"-p", Arg.Set pool, "Pool mode";
		"-d", Arg.Set_string device, "Device to use (real mode only)";
		"-h", Arg.Set_string hosts, "Set the hosts list (comma separated list, first is master, defaults to 'localhost')";
		"-t", Arg.String (fun name' -> name := Some name'), "Sets the name of the test to run";
		"-path", Arg.Set_string vhdd_path, "Path to vhdd binary";
		"-list", Arg.Set list_mode, "Just list the tests";
		"-target", Arg.Set_string target, "Set the ISCSI target";
		"-targetiqn", Arg.Set_string targetiqn, "Set the ISCSI target IQN";
		"-server",Arg.Set_string server, "Set the NFS server";
		"-serverpath",Arg.Set_string serverpath, "Set the NFS serverpath";
		"-localpath",Arg.Set_string localpath, "Set the local path";
		"-scsiid", Arg.Set_string scsiid, "Set the ISCSI SCSI id"]
		(fun _ -> failwith "Invalid argument")
		"Usage:\n\ttest [-m] [-h hosts] [-target target] [-targetiqn targetiqn] [-scsiid scsiid]\n\n";

	Logs.reset_all [ "file:/tmp/test.log" ];

	(Real.device_config :=
		match !backend with
			| "lvm" 
			| "lvmnew" -> 
				["device",!device]
			| "ext" ->
				can_create_raw := false;
				["device",!device]
			| "lvmoiscsi"
			| "lvmnewiscsi" ->
				["target",!target;
				"targetIQN",!targetiqn;
				"SCSIid",!scsiid ]
			| "nfs" -> 
				can_create_raw := false;
				["server",!server;
				"serverpath",!serverpath]
			| "local" -> 
			        can_create_raw := false;
			        ["localpath",!localpath]
			| _ -> failwith (Printf.sprintf "Unknown backend %s" !backend)
	);
				
	(Real.uri := Printf.sprintf "/%s" !backend);

	Real.hosts := String.split ',' !hosts;

	if !real then begin
		init := Real.init;
		cleanup := Real.cleanup
	end else begin
		init := Dummy.init;
		cleanup := Dummy.cleanup
	end;

	let tests = make_module_test_suite "Vhdd"
		([ Basic_tests.tests; Master_restart_tests.tests; Attach_from_config_tests.tests; Parallel_tests.parallel_test;
		Coalesce_tests.tests;
		Vhd_records.Tests.tests;
		(*Killed_operations.get_tests ()*)] @
			(if !pool then [ Basic_tests.tests2; Master_restart_tests.tests2; Attach_from_config_tests.tests2 ] else []))
	in

	let index = index_of_test tests in

	if !list_mode then begin
		List.iter print_endline (List.map fst index);
	end else begin
		let result = run (match !name with | Some name -> List.assoc name index | None -> tests) in

		flush stdout;
		exit (if result.failed = 0 then 0 else 1)
	end
