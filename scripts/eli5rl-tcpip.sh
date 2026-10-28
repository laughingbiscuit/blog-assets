#!/bin/sh
set -ve

# Connect three computers: a client, a router and a server.
# The client asks questions.
# The server sends answers.
# The client and server live on different streets.
# The router is the post office that passes messages between them.

containerlab deploy -c -t - <<'EOF'
name: tcpip

topology:
  nodes:
    # This computer asks questions.
    # It lives on street 10.10.1.x.
    # To reach street 10.10.2.x, it gives messages to the router.
    client:
      kind: linux
      image: ghcr.io/laughingbiscuit/pingpong:latest
      cmd: sleep infinity
      exec:
        - ip addr add 10.10.1.10/24 dev eth1
        - ip route add 10.10.2.0/24 via 10.10.1.1

    # This computer passes messages between the two streets.
    router:
      kind: linux
      image: ghcr.io/laughingbiscuit/pingpong:latest
      cmd: sleep infinity
      exec:
        - ip addr add 10.10.1.1/24 dev eth1
        - ip addr add 10.10.2.1/24 dev eth2
        - sysctl -w net.ipv4.ip_forward=1

    # This computer answers questions.
    # It lives on street 10.10.2.x.
    server:
      kind: linux
      image: ghcr.io/laughingbiscuit/pingpong:latest
      exec:
        - ip addr add 10.10.2.20/24 dev eth1
        - ip route add 10.10.1.0/24 via 10.10.2.1

  # Connect the computers with cables.
  links:
    - endpoints: [client:eth1, router:eth1]
    - endpoints: [router:eth2, server:eth1]
EOF

# These let us tell each computer what to do.
runfromclient() {
  containerlab exec --label clab-node-name=client --cmd "$1"
}
runfromrouter() {
  containerlab exec --label clab-node-name=router --cmd "$1"
}

# ============================================================
# LINK — THE CABLE AND THE NAME BADGE
# This layer moves messages along one cable.
# Each computer wears a name badge called a MAC address.
# ============================================================

# Look at the client's cable and its name badge.
runfromclient 'ip link show eth1'

# Make the client forget every name badge it knows.
runfromclient 'ip neigh flush dev eth1'

# Say hello to the router, and listen on the cable at the same time.
# First the client shouts "Who has 10.10.1.1?" (ARP).
# The router answers with its name badge.
# Then the hello and its reply travel on the cable.
runfromclient 'sh -c "timeout 5 tcpdump -enli eth1 -c 4 arp or icmp 2>/dev/null & sleep 1; ping -c1 -W2 10.10.1.1; wait"'

# Unplug the cable at the router's end.
runfromrouter 'ip link set eth1 down'

# The client can tell nothing is on the other end: NO-CARRIER.
runfromclient 'ip link show eth1'

# Say hello. Nobody can hear us!
runfromclient 'ping -c1 -W2 10.10.1.1' || true

# Plug the cable back in.
runfromrouter 'ip link set eth1 up'
sleep 2

# Say hello again. The router should answer!
runfromclient 'ping -c1 -W2 10.10.1.1'

# ============================================================
# INTERNET — THE POST OFFICE
# Every computer has an IP address, like a house address.
# Messages for another street go to the post office (router).
# The router looks at the address and passes it along.
# ============================================================

# Look at the client's map.
# Street 10.10.1.x is right outside.
# Street 10.10.2.x is "via 10.10.1.1": ask the router.
runfromclient 'ip route'

# Say hello to the server on the other street. It should answer!
runfromclient 'ping -c1 -W2 10.10.2.20'

# Follow the message. Each stop on the way is a "hop".
# First the router, then the server.
runfromclient 'traceroute -n -q1 -w1 10.10.2.20'

# Close the post office.
# The router stops passing messages between streets.
runfromrouter 'sysctl -w net.ipv4.ip_forward=0'

# The router itself still answers...
runfromclient 'ping -c1 -W2 10.10.1.1'

# ...but messages for the other street get stuck!
runfromclient 'ping -c1 -W2 10.10.2.20' || true

# Open the post office again.
runfromrouter 'sysctl -w net.ipv4.ip_forward=1'

# The message gets through!
runfromclient 'ping -c1 -W2 10.10.2.20'

# ============================================================
# TRANSPORT — PHONE CALL OR POSTCARD?
# TCP is like a phone call.
# First we say "hello?", "hello!", "great, let's talk".
# UDP is like a postcard.
# We just send it and hope it arrives.
# ============================================================

# Make a TCP phone call to door (port) 80, and listen on the cable.
# Look at the Flags:
#   [S]  client: "Hello? Can we talk?"      (SYN)
#   [S.] server: "Hello! Yes we can."       (SYN-ACK)
#   [.]  client: "Great, let's talk."       (ACK)
runfromclient 'sh -c "timeout 5 tcpdump -nli eth1 -c 3 tcp port 80 2>/dev/null & sleep 1; curl -s -o /dev/null http://10.10.2.20/ping; wait"'

# Call door 81. Nobody is there.
# The server hangs up straight away: [R] means "reset".
runfromclient 'sh -c "timeout 5 tcpdump -nli eth1 -c 2 tcp port 81 2>/dev/null & sleep 1; curl -s --max-time 2 http://10.10.2.20:81/; wait"'

# Send a UDP postcard to door 9999.
# No "hello" first. The postcard just goes.
# Nobody lives there, so the server sends back a note:
# "port 9999 unreachable".
runfromclient 'sh -c "timeout 5 tcpdump -nli eth1 -c 2 udp port 9999 or icmp 2>/dev/null & sleep 1; echo hello | nc -u -w1 10.10.2.20 9999; wait"'

# ============================================================
# APPLICATION — ASKING FOR A PAGE
# This is the message itself.
# It is written in a language both computers understand: HTTP.
# In this model, looking after the conversation and turning
# messages into special-looking letters both happen here too.
# ============================================================

# HTTP is just words!
# Type a request by hand and send it through door 80.
# dos2unix hides the invisible end-of-line marks (\r) that HTTP
# puts after each line.
runfromclient 'sh -c "printf \"GET /ping HTTP/1.0\\r\\n\\r\\n\" | nc -w2 10.10.2.20 80 | dos2unix"'

# Ask for a page that exists.
# 200 means: "Here it is!"
runfromclient 'sh -c "curl -si --max-time 5 http://10.10.2.20/ping | dos2unix"'

# Ask for a page that doesn't exist.
# 404 means: "I can't find it!"
runfromclient 'sh -c "curl -si --max-time 5 http://10.10.2.20/nope | dos2unix"'

# Ask for a message written in Base64, then turn it back.
runfromclient 'sh -c "curl -sS --max-time 5 http://10.10.2.20/encoded | base64 -d"'
