#!/usr/bin/env python3

import subprocess
import re
import sys
import json
import argparse

moongen_dir = "MoonGen"

nodeinfo_skeleton = {
    "sender1": {"hostname": None,
                "cn-ip": None,
                "if": {"ifname":None, "ip":"10.10.1.1", "net":"10.10.1.0/24"}
                },
    "sender2": {"hostname": None,
                "cn-ip": None,
                "if": {"ifname":None, "ip":"10.10.2.1", "net":"10.10.2.0/24"}
                },
    "router1": {"hostname": None,
                "cn-ip": None,
                "if-r-1": {"ifname":None, "ip":"10.10.1.2", "net":"10.10.1.0/24"},
                "if-r-2": {"ifname":None, "ip":"10.10.2.2", "net":"10.10.2.0/24"},
                "if-r-r": {"ifname":None, "ip":"10.10.5.1", "net":"10.10.5.0/24"}
                },
    "router2": {"hostname": None,
                "cn-ip": None,
                "if-r-1": {"ifname":None, "ip":"10.10.3.2", "net":"10.10.3.0/24"},
                "if-r-2": {"ifname":None, "ip":"10.10.4.2", "net":"10.10.4.0/24"},
                "if-r-r": {"ifname":None, "ip":"10.10.5.2", "net":"10.10.5.0/24"}
                },
    "receiver1": {"hostname": None,
                  "cn-ip": None,
                  "if": {"ifname":None, "ip":"10.10.3.1", "net":"10.10.3.0/24"}
                  },
    "receiver2": {"hostname": None,
                  "cn-ip": None,
                  "if": {"ifname":None, "ip":"10.10.4.1", "net":"10.10.4.0/24"}
                  },
    "mg_router": {"hostname": None,
                  "cn-ip": None,
                  "ifaces":[{"ifname":None, "ip":"10.10.5.101", "idx":None, "net":"10.10.5.0/24"},
                            {"ifname":None, "ip":"10.10.5.102", "idx":None, "net":"10.10.5.0/24"}],
                  "links":None
                  }
    }


def locate_nodes(nodeinfo, exp_name, project='rnlab'):
    for n in nodeinfo.keys():
        print("locating node ",n, file=sys.stderr)
        node_located = False
        nslookup_cmd = "nslookup "+n+"."+exp_name+"."+project+".filab.uni-hannover.de"
        ns_out =  subprocess.run(f"nslookup "+n+"."+exp_name+"."+project+".filab.uni-hannover.de",
                                 shell=True, stdout=subprocess.PIPE)
        for line in ns_out.stdout.decode().split("\n"):
            #print("\tprocessing line: ",line, file=sys.stderr)
            cname = re.search(r"canonical\s+name\s+=\s+(\S+.uni-hannover.de)", line)
            #cname = re.search(r"canonical\s+name\s+\=\s+\w+.uni-hannover.de", line)
            if cname:
                print("\tcname match: ",cname.group(1), file=sys.stderr)
                nodeinfo[n]['hostname'] = cname.group(1)
                node_located = True
            addr = re.search(r"Address:\s+(\d+\.\d+\.\d+\.\d+)$", line)
            if addr:
                print("\taddr match: ", addr.group(1), file=sys.stderr)
                nodeinfo[n]['cn-ip'] = addr.group(1)
        if not node_located:
            print("ERROR: could not locate node: "+n+"."+exp_name+"."+project+".filab.uni-hannover.de", file=sys.stderr)
            sys.exit(-1)


def query_endpoint(nodeinfo):
    # given the pc name, and the skeleton of the node info that is common to all
    # dumbells, fill in the interface names and (for routers) the links
    print("gathering info from endpoint ", nodeinfo['hostname'], file=sys.stderr)
    ip_addr_cmd = "ip --brief a show"
    ip_out =  subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+ip_addr_cmd+"'",
                               shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    for line in ip_out[0].decode().split("\n"):
        #print("\tprocessing line: ",line, file=sys.stderr)
        fields = line.split()
        if len(fields) >=3:
            (ifname, state, ipv4) = fields[0:3]
            (ip,mask) = ipv4.split('/')
            if nodeinfo['if']['ip'] == ip:
                print("\tdiscovered the interface for ip: ", ifname, ip, file=sys.stderr)
                nodeinfo['if']['ifname'] = ifname


def query_router(nodeinfo):
    # given the pc name, and the skeleton of the node info that is common to all
    # dumbells, fill in the interface names and (for routers) the links
    print("gathering info from router ", nodeinfo['hostname'], file=sys.stderr)
    ip_addr_cmd = "ip --brief a show"
    ip_out =  subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+ip_addr_cmd+"'",
                               shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    for line in ip_out[0].decode().split("\n"):
        #print("\tprocessing line: ",line, file=sys.stderr)
        fields = line.split()
        if len(fields) >=3:
            (ifname, state, ipv4) = fields[0:3]
            (ip,mask) = ipv4.split('/')
            # this is klunky...
            if nodeinfo['if-r-1']['ip'] == ip:
                print("\tdiscovered the interface for ip: ", ifname, ip, file=sys.stderr)
                nodeinfo['if-r-1']['ifname'] = ifname
            if nodeinfo['if-r-2']['ip'] == ip:
                print("\tdiscovered the interface for ip: ", ifname, ip, file=sys.stderr)
                nodeinfo['if-r-2']['ifname'] = ifname
            if nodeinfo['if-r-r']['ip'] == ip:
                print("\tdiscovered the interface for ip: ", ifname, ip, file=sys.stderr)
                nodeinfo['if-r-r']['ifname'] = ifname


def query_moongen(nodeinfo):
    # given the pc name, and the skeleton of the node info that is common to all
    # dumbells, fill in the interface names and (for routers) the links
    # for moongen nodes, we also need to figure out the link membership
    print("gathering info from moongen node ", nodeinfo['hostname'], file=sys.stderr)
    ip_addr_cmd = "ip --brief a show"
    ip_out =  subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+ip_addr_cmd+"'",
                               shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    usable_interfaces = []
    iface_idx = -1
    for line in ip_out[0].decode().split("\n"):
        #print("\tprocessing line: ",line, file=sys.stderr)
        if ("DOWN" in line) or ("10.10." in line):
            iface_idx += 1
        fields = line.split()
        if len(fields) >=3:
            (ifname, state, ipv4) = fields[0:3]
            (ip,mask) = ipv4.split('/')
            for ifinfo in nodeinfo['ifaces']:
                if ifinfo['ip'] == ip:
                    print("\tdiscovered the interface for ip: ", ifname, ip, iface_idx, file=sys.stderr)
                    ifinfo['ifname'] = ifname
                    ifinfo['idx'] = iface_idx
                    usable_interfaces.append(ifname)
    if len(usable_interfaces) != len(nodeinfo['ifaces']):
        print("ERROR: did not find enough usable interfaces to match the config skeleton!", len(usable_interfaces), len(nodeinfo['ifaces']), file=sys.stderr)
        #sys.exit(-2)
    else:
        usable_interfaces.sort()
        print("\tusable interfaces: ",usable_interfaces, file=sys.stderr)
        link_pool = {}
        for ifinfo in nodeinfo['ifaces']:
            ip_prefix = re.search(r"10.10.\d+.", ifinfo['ip']).group()
            #print("\tregex matched: ", ip_prefix, ifinfo['ifname'], file=sys.stderr)
            if ip_prefix not in link_pool:
                link_pool[ip_prefix] = []
            link_pool[ip_prefix].append(ifinfo['idx']) 
            
        #print("\tlink pool: ",link_pool, file=sys.stderr)
        nodeinfo['links'] = []
        for ip_prefix,ll in link_pool.items():
            #print("\tinterfaces in common link: ", ll, file=sys.stderr)
            nodeinfo['links'].append(ll)
        print("\tlinks: ", nodeinfo['links'], file=sys.stderr)


def setup_endpoint(nodeinfo, routerip):
    # on the tx/rx nodes, the only thing to set up is the routing table
    # first we have to clear out the junk entries that emulab put
    print("\n\nconfiguring endpoint ",nodeinfo['hostname'], file=sys.stderr)
    route_info = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" 'ip route show'",
                                  shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("got response: \n",route_info[0].decode(), file=sys.stderr)
    # we want to get rid of anything mentioning 10.10.x.x
    for r in route_info[0].decode().split("\n"):
        #print("processing line: ",r, file=sys.stderr)
        if "default" not in r:
            if "10.10." in r:
                delete_command = "sudo ip route del "+r
                print("delete command: ",delete_command, file=sys.stderr)
                response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+delete_command+"'",
                                  shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
                print("response: ", response, file=sys.stderr)
    add_command = "sudo ip route add "+nodeinfo['if']['net']+" dev "+nodeinfo['if']['ifname']+" proto kernel scope link src "+nodeinfo['if']['ip']+"; sudo ip route add 10.10.0.0/16 via "+routerip+" dev "+nodeinfo['if']['ifname']
    print("add command: ",add_command, file=sys.stderr)
    response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+add_command+"'",
                                shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("response: ", response, file=sys.stderr)
    noofload_cmd = "~/../rnlabad/nooffload.sh "+nodeinfo["if"]["ifname"]
    print("noofload command: ", noofload_cmd)
    response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+noofload_cmd+"'",
                                shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("response: ", response, file=sys.stderr)
    

def setup_router(nodeinfo, routerip):
    # on the router we need to delete extraneous route junk,
    # and set up the default through the other router
    # what about routes like:
    #   10.10.1.0/24 dev enp7s0f1 proto kernel scope link src 10.10.1.2
    print("\n\nconfiguring router ",nodeinfo['hostname'], file=sys.stderr)
    route_info = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" 'ip route show'",
                                  shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("got response: \n",route_info[0].decode(), file=sys.stderr)
    # we want to get rid of anything mentioning 10.10.x.x
    for r in route_info[0].decode().split("\n"):
        #print("processing line: ",r, file=sys.stderr)
        if "default" not in r:
            if "10.10." in r:
                delete_command = "sudo ip route del "+r
                print("delete command: ",delete_command, file=sys.stderr)
                response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+delete_command+"'",
                                  shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
                print("response: ", response, file=sys.stderr)
    add_command = "sudo ip route add "+nodeinfo['if-r-r']['net']+" dev "+nodeinfo['if-r-r']['ifname']+" proto kernel scope link src "+nodeinfo['if-r-r']['ip']
    add_command += "; sudo ip route add "+nodeinfo['if-r-1']['net']+" dev "+nodeinfo['if-r-1']['ifname']+" proto kernel scope link src "+nodeinfo['if-r-1']['ip']
    add_command += "; sudo ip route add "+nodeinfo['if-r-2']['net']+" dev "+nodeinfo['if-r-2']['ifname']+" proto kernel scope link src "+nodeinfo['if-r-2']['ip']
    add_command += "; sudo ip route add 10.10.0.0/16 via "+routerip+" dev "+nodeinfo['if-r-r']['ifname']
    print("add command: ",add_command, file=sys.stderr)
    response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+add_command+"'",
                                shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("response: ", response, file=sys.stderr)
    noofload_cmd = "~/../rnlabad/nooffload.sh "+nodeinfo["if-r-1"]["ifname"]+" " +nodeinfo["if-r-2"]["ifname"]+" "+nodeinfo["if-r-r"]["ifname"]
    print("noofload command: ", noofload_cmd)
    response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+noofload_cmd+"'",
                                shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("response: ", response, file=sys.stderr)


def install_moongen_dependencies(nodeinfo):
    # to just run moongen we only need to add:
    # libtbb2 libtbb-dev
    deps = ["htop", "libtbb2", "libtbb-dev"]
    quagga_sed_cmd = "sudo sed -i \"/\b\(quagga\)\b/d\" /var/lib/dpkg/statoverride"
    print("quagga sed command: ", quagga_sed_cmd, file=sys.stderr)
    response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+quagga_sed_cmd+"'",
                                shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("response: ", response, file=sys.stderr)
    response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" 'sudo apt update'",
                                shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("response: ", response, file=sys.stderr)
    response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" 'sudo apt install "+" ".join(deps)+"'",
                                shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("response: ", response, file=sys.stderr)

    
def setup_moongen(nodeinfo, rate, latency=0, queue=0):
    # this is the tough one!
    # assume thr nodeinfo already contains the info about which
    # interfaces to link together

    install_moongen_dependencies(nodeinfo)

    print("\n\nconfiguring moongen ",nodeinfo['hostname'], file=sys.stderr)
    # first take the interfaces down
    if_down_cmd = ""
    for iface in nodeinfo['ifaces']:
        if_down_cmd += "sudo ifconfig "+iface['ifname']+" down; "
    print("ifdown command: ",if_down_cmd, file=sys.stderr)
    response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+if_down_cmd+"'",
                                shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("response: ", response, file=sys.stderr)
    
    # setup hugepages
    hugepage_cmd = "cd "+moongen_dir+"; sudo ./setup-hugetlbfs.sh"
    #response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+hugepage_cmd+"'",
    #                            shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("hugepage_cmd: "+hugepage_cmd, file=sys.stderr)
    response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+hugepage_cmd+"'",
                                shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("response: ", response, file=sys.stderr)
    
    # bind the interfaces
    bind_interfaces_cmd = "cd "+moongen_dir+"; sudo ./bind-interfaces.sh"
    #response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+bind_interfaces_cmd+"'",
    #                            shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("bind_interfaces_cmd: "+bind_interfaces_cmd, file=sys.stderr)
    response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+bind_interfaces_cmd+"'",
                                shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("response: ", response, file=sys.stderr)

    # cleanup old moongen processes
    mg_kill_cmd = "sudo killall MoonGen; sleep 5; sudo killall MoonGen"
    response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+mg_kill_cmd+"'",
                                shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("response: ", response, file=sys.stderr)
    
    # run moongen
    links = nodeinfo['links']
    moongen_cmd = ""
    if len(links) == 1:
        if latency==0:
            moongen_cmd = "sudo nohup MoonGen/build/MoonGen MoonGen/examples/l2-forward-rate-crc.lua "+str(links[0][0])+" "+str(links[0][1])+" "+str(rate)+" "+str(rate)+" > /tmp/mglog-"+str(links[0][0])+".log 2>&1 &"
        else:
            if queue==0:
                moongen_cmd = "sudo nohup MoonGen/build/MoonGen MoonGen/examples/l2-forward-bsring-lrl.lua -d "+str(links[0][0])+" "+str(links[0][1])+" -r "+str(rate)+" "+str(rate)+" -l "+str(latency)+" "+str(latency)+" -x 20000 20000 > /tmp/mglog-"+str(links[0][0])+".log 2>&1 &"
            else:
                moongen_cmd = "sudo nohup MoonGen/build/MoonGen MoonGen/examples/l2-forward-psring-lrl.lua -d "+str(links[0][0])+" "+str(links[0][1])+" -r "+str(rate)+" "+str(rate)+" -l "+str(latency)+" "+str(latency)+" -q "+str(queue)+" "+str(queue)+" > /tmp/mglog-"+str(links[0][0])+".log 2>&1 &"
    elif len(links) == 2:
        moongen_cmd = "sudo nohup MoonGen/build/MoonGen MoonGen/examples/l2-multi-forward-rate-crc.lua "+str(links[0][0])+" "+str(links[0][1])+" "+str(links[1][0])+" "+str(links[1][1])+" "+str(rate)+" "+str(rate)+" "+str(rate)+" "+str(rate)+" > /tmp/mglog-"+str(links[0][0])+".log 2>&1 &"
            
    print("moongen_cmd: "+moongen_cmd, file=sys.stderr)
    response = subprocess.Popen(f"ssh -o StrictHostKeyChecking=no "+nodeinfo['hostname']+" '"+moongen_cmd+"'",
                                shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    print("response: ", response, file=sys.stderr)


def gather_config(nodeinfo, exp_name, proj_name):
    # when the experiment is first created, this will gather all the
    # experiment-specific info needed to configure the nodes routing
    # tables, and start moongen on the emulators
    #
    # This will not work once the moongen nodes have been started, since
    # running moongen destroys the boot-time interface configuration
    #
    locate_nodes(nodeinfo, exp_name, proj_name)
    print("\n\n\n", file=sys.stderr)
    query_endpoint(nodeinfo['sender1'])
    query_endpoint(nodeinfo['sender2'])
    query_endpoint(nodeinfo['receiver1'])
    query_endpoint(nodeinfo['receiver2'])
    print("\n\n\n", file=sys.stderr)
    query_router(nodeinfo['router1'])
    query_router(nodeinfo['router2'])
    print("\n\n\n", file=sys.stderr)
    #query_moongen(nodeinfo['mg_sender'])
    #query_moongen(nodeinfo['mg_receiver'])
    query_moongen(nodeinfo['mg_router'])

def print_config(nodeinfo):
    print(json.dumps(nodeinfo, sort_keys=True, indent=4))


def load_config(filename):
    # load the json format config file for this experiment
    with open(filename, 'r') as f:
        nodeinfo = json.load(f)
        print("read file: \n", nodeinfo)
    return nodeinfo

    
def configure_nodes(nodeinfo, bottleneck_rate, tx_rate, rx_rate, bottleneck_latency, queue_depth):
    setup_endpoint(nodeinfo['sender1'], nodeinfo['router1']['if-r-1']['ip'])
    setup_endpoint(nodeinfo['sender2'], nodeinfo['router1']['if-r-2']['ip'])
    setup_endpoint(nodeinfo['receiver1'], nodeinfo['router2']['if-r-1']['ip'])
    setup_endpoint(nodeinfo['receiver2'], nodeinfo['router2']['if-r-2']['ip'])
    print("\n\n\n")
    setup_router(nodeinfo['router1'], nodeinfo['router2']['if-r-r']['ip'])
    setup_router(nodeinfo['router2'], nodeinfo['router1']['if-r-r']['ip'])
    print("\n\n\n")
    #setup_moongen(nodeinfo['mg_sender'], tx_rate)
    #setup_moongen(nodeinfo['mg_receiver'], rx_rate)
    setup_moongen(nodeinfo['mg_router'], bottleneck_rate, latency=bottleneck_latency, queue=queue_depth)

# ======================================
# ======================================
# ======================================

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-e", dest='exp_name', help='experiment name')
    parser.add_argument("-p", dest='proj_name', help='project name (default=rnlab)', default='rnlab')
    parser.add_argument("-j", dest='nodeinfo', help='load json config file for experiment')
    parser.add_argument("-b", dest='bottleneck_rate', help='bottleneck link rate in Mbps', type=int, default=5)
    parser.add_argument("-s", dest='sender_rate', help='sender nodes\' link rate in Mbps', type=int, default=10)
    parser.add_argument("-r", dest='receiver_rate', help='receiver nodes\' link rate in Mbps', type=int, default=10)
    parser.add_argument("-l", dest='bottleneck_latency', help='bottleneck link latency in ms', type=int, default=0)
    parser.add_argument("-q", dest='queue', help='use the packet-sized ring, and manually set queue depth', type=int, default=0)
    args = parser.parse_args()

    if args.exp_name:
        if args.nodeinfo:
            print("ERROR: cannot use both -e and -j arguments\n")
            parser.print_help()
            sys.exit(0)
    else:
        if not args.nodeinfo:
            print("ERROR: must specify either -e or -j argument\n")
            parser.print_help()
            sys.exit(0)

    if args.exp_name:
        nodeinfo = nodeinfo_skeleton
        gather_config(nodeinfo, args.exp_name, args.proj_name)
        print_config(nodeinfo)
    elif args.nodeinfo:
        nodeinfo = load_config(args.nodeinfo)
        configure_nodes(nodeinfo, args.bottleneck_rate, args.sender_rate, args.receiver_rate, args.bottleneck_latency, args.queue)

        
# ======================================
# ======================================
# ======================================
        
if __name__ == "__main__":
    main()

    
