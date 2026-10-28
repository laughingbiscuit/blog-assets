#!/bin/sh
set -ve

# Connect two computers: a client and a server.
# The client asks questions.
# The server sends answers.

containerlab deploy -c -t - <<'EOF'
name: osi

topology:
  nodes:
    # This computer answers questions.
    server:
      kind: linux
      image: ghcr.io/laughingbiscuit/pingpong:latest
      exec:
        - ip addr add 10.10.0.20/24 dev eth1

    # This computer asks questions.
    client:
      kind: linux
      image: ghcr.io/laughingbiscuit/pingpong:latest
      cmd: sleep infinity
      exec:
        - ip addr add 10.10.0.10/24 dev eth1

  # Connect both computers with a cable.
  links:
    - endpoints: [client:eth1, server:eth1]
EOF

# This lets us tell the client what to do.
runfromclient() {
  containerlab exec --label clab-node-name=client --cmd "$1"
}

# ============================================================
# L1 PHYSICAL — THE CABLE
# ============================================================

# Say hello to the server. It should answer!
runfromclient 'ping -I eth1 -c1 -W2 10.10.0.20'

# Unplug the cable.
# Stop all messages going in either direction.
containerlab tools netem set -n clab-osi-client -i eth1 --loss 100
containerlab tools netem set -n clab-osi-server -i eth1 --loss 100

# No messages get through.
runfromclient 'ping -I eth1 -c1 -W2 10.10.0.20' || true

# Plug the cable back in.
containerlab tools netem set -n clab-osi-client -i eth1
containerlab tools netem set -n clab-osi-server -i eth1

# Say hello again. The server should answer!
runfromclient 'ping -I eth1 -c1 -W2 10.10.0.20'

# ============================================================
# L2 DATA LINK — NAME BADGE
# Each computer has a special name badge called a MAC address.
# What happens if we use the wrong name badge?
# ============================================================

# Look at the server's real name badge.
containerlab inspect interfaces --name osi --node clab-osi-server

# Say hello so the client learns the server's name badge.
runfromclient 'ping -I eth1 -c1 -W2 10.10.0.20'

# See the name badge the client remembers.
runfromclient 'ip neigh show dev eth1'

# Trick the client into remembering a wrong name badge.
runfromclient \
  'ip neigh replace 10.10.0.20 lladdr de:ad:be:ef:00:01 nud permanent dev eth1'

# Say hello. The message goes to the wrong name badge!
runfromclient 'ping -I eth1 -c1 -W2 10.10.0.20' || true

# Look at the wrong name badge.
runfromclient 'ip neigh show dev eth1'

# Make the client forget the wrong name badge.
runfromclient 'ip neigh del 10.10.0.20 dev eth1'

# Say hello. The client can learn the right one again!
runfromclient 'ping -I eth1 -c1 -W2 10.10.0.20'
runfromclient 'ip neigh show dev eth1'

# ============================================================
# L3 NETWORK — THE MAP
# Computers use IP addresses like house addresses.
# A route is like a map showing where to go.
# What happens if the map gives bad directions?
# ============================================================

# Show the good path to the server.
runfromclient 'ip route get 10.10.0.20'

# Say hello. Everything works!
runfromclient 'ping -c1 -W2 10.10.0.20'

# Give the client a bad map.
# Tell it to send messages through a place that isn't there.
runfromclient \
  'ip route add 10.10.0.20/32 via 10.10.0.254 dev eth1 onlink'

# Look at the bad directions.
runfromclient 'ip route get 10.10.0.20'

# Say hello. The message gets lost!
runfromclient 'ping -c1 -W2 10.10.0.20' || true

# Throw away the bad directions.
runfromclient 'ip route del 10.10.0.20/32'

# The good path works again!
runfromclient 'ip route get 10.10.0.20'
runfromclient 'ping -c1 -W2 10.10.0.20'

# ============================================================
# L4 TRANSPORT — THE DOORS
# A computer has numbered doors called ports.
# Some doors are open. Others are closed.
# Messages can also be slow or get lost.
# ============================================================

# Knock on door 80. Someone should answer!
# 2>&1 shows curl's chatter even when it works, so we can see
# "Established connection".
runfromclient 'sh -c "curl -sv --max-time 5 \
  http://10.10.0.20/ping 2>&1 | dos2unix"'

# Knock on door 81. Nobody is listening!
runfromclient \
  'curl -sv --connect-timeout 2 --max-time 3 \
  http://10.10.0.20:81/ping' || true

# See how fast the server answers.
runfromclient 'curl -sS --max-time 5 -o /dev/null \
  -w "connect=%{time_connect}s total=%{time_total}s" \
  http://10.10.0.20/ping'

# Make the path bumpy!
# Messages must wait longer.
# A few messages may get lost.
containerlab tools netem set -n clab-osi-client -i eth1 \
  --delay 200ms --jitter 50ms --loss 20
containerlab tools netem set -n clab-osi-server -i eth1 \
  --delay 200ms --jitter 50ms --loss 20

# Look at the bumps we added.
containerlab tools netem show -n clab-osi-client

# Send five hellos. Are some slow or missing?
runfromclient 'ping -I eth1 -c5 -W2 10.10.0.20' || true

# Ask for a page. It may take longer to arrive!
runfromclient 'curl -sS --max-time 12 -o /dev/null \
  -w "connect=%{time_connect}s total=%{time_total}s" \
  http://10.10.0.20/ping' || true

# Make the path smooth again.
containerlab tools netem set -n clab-osi-client -i eth1
containerlab tools netem set -n clab-osi-server -i eth1

# Ask again. The server should answer quickly!
runfromclient 'curl -sS --max-time 5 -o /dev/null \
  -w "connect=%{time_connect}s total=%{time_total}s" \
  http://10.10.0.20/ping'

# ============================================================
# L5 SESSION — THE PHONE CALL
# Imagine calling a friend.
# You can keep the call open and ask two questions.
# Or hang up and call again for each question.
# ============================================================

# Ask two questions using the same call if possible.
# The numbers tell us if a new call was needed.
runfromclient 'curl -sS --max-time 5 --http1.1 \
  -o /dev/null -o /dev/null \
  -w "connections=%{num_connects} " \
  http://10.10.0.20/ping http://10.10.0.20/ping'

# Now hang up after each question.
# Each question should need a new call.
runfromclient 'curl -sS --max-time 5 --http1.1 \
  -H "Connection: close" -o /dev/null -o /dev/null \
  -w "connections=%{num_connects} " \
  http://10.10.0.20/ping http://10.10.0.20/ping'

# ============================================================
# L6 PRESENTATION — THE SECRET-LOOKING MESSAGE
# Sometimes computers change how a message is written.
# Base64 turns a message into special-looking letters.
# We can change it back so we can read it.
# ============================================================

# Ask for a message written in Base64.
runfromclient 'curl -sS --max-time 5 \
  http://10.10.0.20/encoded'

# Turn it back into a message we can read.
runfromclient 'sh -c "curl -sS --max-time 5 \
  http://10.10.0.20/encoded | base64 -d"'

# Now try changing a normal message back.
# Oops! It wasn't written in Base64!
runfromclient 'sh -c "curl -sS --max-time 5 \
  http://10.10.0.20/ping | base64 -d 2>&1"' || true

# ============================================================
# L7 APPLICATION — ASKING FOR A PAGE
# The client asks the server for something.
# If the server has it, we get 200.
# If the server can't find it, we get 404.
# ============================================================

# Ask for a page that exists.
# 200 means: "Here it is!"
# dos2unix hides the invisible end-of-line marks (\r) that HTTP
# puts after each header.
runfromclient 'sh -c "curl -si --max-time 5 \
  http://10.10.0.20/ping | dos2unix"'

# Ask for a page that doesn't exist.
# 404 means: "I can't find it!"
runfromclient 'sh -c "curl -si --max-time 5 \
  http://10.10.0.20/nope | dos2unix"'
