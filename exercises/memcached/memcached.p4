/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>

const bit<16> TYPE_IPV4 = 0x800;
const bit<8>  PROTOCOL_UDP = 0x11;
const bit<16>  MEMCACHED_REQUEST = 0x1a;
contst bit<16> MEMCACHED_RESPONSE = 0x2e;

/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

header udp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> length_;
    bit<16> checksum;
}

header memcached_response_t{
    bit<64> zeroMagic;
    bit<40> valueMagic;
    bit<8>  space;
    bit<192> ResponseContent;
}

header memcached_request_t {
    bit<64> notNeeded;
    bit<24> getKeyWord;
    bit<8> space;
    bit<32> key;
    bit<8> lastCharKey;
    bit<8> endPacket;
}

struct metadata {
    /* empty */
}

struct headers {
    ethernet_t   	ethernet;
    ipv4_t       	ipv4;
    udp_t	 	udp;
    memcached_request_t memcached_request;
    memcached_response_t memcached_response;
}


/*************************************************************************
*********************** P A R S E R  ***********************************
*************************************************************************/

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
	    PROTOCOL_UDP: parse_udp;
            default: accept;
        }
    }
    
    state parse_udp {
        packet.extract(hdr.udp);
        transition select(hdr.udp.length_) {
	    MEMCACHED_REQUEST: parse_memcached_request;
	    MEMCACHED_RESPONSE: parse_memcached_response;
            default: accept;
        }
    }
    
    state parse_memcached_response {
        packet.extract(hdr.memcached_response);
        transition accept;
    }
    
    state parse_memcached_request {
        packet.extract(hdr.memcached_request);
        transition accept;
    }
        
}

/*************************************************************************
************   C H E C K S U M    V E R I F I C A T I O N   *************
*************************************************************************/

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {   
    apply {  }
}


/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {
    action drop() {
        mark_to_drop(standard_metadata);
    }
    
    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }
      action rewrite_ipv4_src(ip4Addr_t srcAddr) {
        bit<32> original_srcAddr;
	
	// replace src address
	original_srcAddr = hdr.ipv4.srcAddr;
	hdr.ipv4.srcAddr = srcAddr;
        hdr.udp.checksum = hdr.udp.checksum - (bit<16>)(srcAddr - original_srcAddr);
    }
    
    action rewrite_ipv4_dst(ip4Addr_t dstAddr) {
        bit<32> original_dstAddr;
	
	// replace dest address
	original_dstAddr = hdr.ipv4.dstAddr;
	hdr.ipv4.dstAddr = dstAddr;
	// hdr.ipv4.srcAddr remains the same 
        hdr.udp.checksum = hdr.udp.checksum - (bit<16>)(dstAddr - original_dstAddr);
    }
    
     table memcached_request_load_balancing {
        key = {
            hdr.memcached_request.lastDigit: exact;
        }
        actions = {
            rewrite_ipv4_dst;
            drop;
            NoAction;
        }
        size = 8;
        default_action = drop();
    }
    
    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = drop();
    }
    
    table memcached_response_forwarding {
        key = {
            hdr.memcached_request.ResponseContent: exact;
        }
        actions = {
            rewrite_ipv4_src;
            drop;
            NoAction;
        }
        size = 1024;
    }
    
    
  

    apply {
        if(hdr.ipv4.isValid())
	{
		if (hdr.memcached_request.isValid()) {
            		memcached_request_load_balancing.apply();
        	}
		if (hdr.memcached_response.isValid()) {
            		memcached_response_forwarding.apply();
        	}
	ipv4_lpm.apply();
    	}
    }
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    apply {  }
}

/*************************************************************************
*************   C H E C K S U M    C O M P U T A T I O N   **************
*************************************************************************/

control MyComputeChecksum(inout headers  hdr, inout metadata meta) {
     apply {
	update_checksum(
	    hdr.ipv4.isValid(),
            { hdr.ipv4.version,
	      hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

/*************************************************************************
***********************  D E P A R S E R  *******************************
*************************************************************************/

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
     packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
	packet.emit(hdr.udp);
	packet.emit(hdr.memcached_request);
	packet.emit(hdr.memchache_response);
    }
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;