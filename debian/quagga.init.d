#!/bin/bash
#
### BEGIN INIT INFO
# Provides: quagga
# Required-Start: $local_fs $network $remote_fs $syslog
# Required-Stop: $local_fs $network $remote_fs $syslog
# Default-Start:  2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: start and stop the Quagga routing suite
# Description: Quagga is a routing suite for IP routing protocols like 
#              BGP, OSPF, RIP and others. This script contols the main 
#              daemon "quagga" as well as the individual protocol daemons.
### END INIT INFO
#

PATH=/bin:/usr/bin:/sbin:/usr/sbin
D_PATH=/usr/lib/quagga
C_PATH=/etc/quagga
V_PATH=/var/run/quagga

# Local Daemon selection may be done by using /etc/quagga/daemons.
# See /usr/share/doc/quagga/README.Debian.gz for further information.
# Keep zebra first and do not list watchquagga!
DAEMONS="zebra bgpd ripd ripngd ospfd ospf6d isisd babeld"
MAX_INSTANCES=5
RELOAD_SCRIPT=/usr/lib/quagga/quagga-reload.py

# Print the name of the pidfile.
pidfile()
{
    echo "$V_PATH/$1.pid"
}

# Print the name of the vtysh.
vtyfile()
{
    echo "$V_PATH/$1.vty"
}

# Check if daemon is started by using the pidfile.
started()
{
        [ ! -e `pidfile $1` ] && return 3
	kill -0 `cat \`pidfile $1\`` 2> /dev/null || return 1
	return 0
}

# Loads the config via vtysh -b if configured to do so.
vtysh_b ()
{
        # Rember, that all variables have been incremented by 1 in convert_daemon_prios()
        if [ "$vtysh_enable" = 2 -a -f $C_PATH/Quagga.conf ]; then
                /usr/bin/vtysh -b
        fi
}

# Check if the daemon is activated and if its executable and config files 
# are in place.
# params:       daemon name
# returns:      0=ok, 1=error
check_daemon()
{
        # If the integrated config file is used the others are not checked.
        if [ -r "$C_PATH/Quagga.conf" ]; then
          return 0
        fi 

        # vtysh_enable has no config file nor binary so skip check.
        # (Not sure why vtysh_enable is in this list but does not hurt)
        if [ $1 != "watchquagga" -a $1 != "vtysh_enable" ]; then
          # check for daemon binary
          if [ ! -x "$D_PATH/$1" ]; then return 1; fi
                
          # check for config file
          if [ -n "$2" ]; then
	    if [ ! -r "$C_PATH/$1-$2.conf" ]; then
                touch "$C_PATH/$1-$2.conf"
                chown quagga:quagga "$C_PATH/$1-$2.conf"
	    fi
          elif [ ! -r "$C_PATH/$1.conf" ]; then
            touch "$C_PATH/$1.conf"
            chown quagga:quagga "$C_PATH/$1.conf"
          fi
        fi
        return 0
}

# Starts the server if it's not alrady running according to the pid file.
# The Quagga daemons creates the pidfile when starting.
start()
{
        if [ "$1" = "watchquagga" ]; then

	    # We may need to restart watchquagga if new daemons are added and/or
	    # removed
	    if started "$1" ; then
		stop watchquagga
	    else
		# Echo only once. watchquagga is printed in the stop above
		echo -n " $1"
	    fi

            start-stop-daemon \
                --start \
                --pidfile=`pidfile $1` \
                --exec "$D_PATH/$1" \
                -- \
                "${watchquagga_options[@]}"
        elif [ -n "$2" ]; then
	   echo -n " $1-$2"
           if ! check_daemon $1 $2 ; then
	       echo -n " (binary does not exist)"
	       return;
	   fi

           start-stop-daemon \
               --start \
               --pidfile=`pidfile $1-$2` \
               --exec "$D_PATH/$1" \
               -- \
               `eval echo "$""$1""_options"` -n "$2"
        else
	    echo -n " $1"
            if ! check_daemon $1; then
	        echo -n " (binary does not exist)"
		return;
	    fi

	    start-stop-daemon \
		--start \
		--pidfile=`pidfile $1` \
		--exec "$D_PATH/$1" \
		-- \
		`eval echo "$""$1""_options"`
        fi
}

# Stop the daemon given in the parameter, printing its name to the terminal.
stop()
{
    local inst

    if [ -n "$2" ]; then
	inst="$1-$2"
    else
	inst="$1"
    fi

    if ! started "$inst" ; then
        echo -n " ($inst)"
        return 0
    else
        PIDFILE=`pidfile $inst`
        PID=`cat $PIDFILE 2>/dev/null`
        start-stop-daemon --stop --quiet --oknodo --pidfile "$PIDFILE" --exec "$D_PATH/$1"
        #
        #       Now we have to wait until $DAEMON has _really_ stopped.
        #
        if test -n "$PID" && kill -0 $PID 2>/dev/null; then
            echo -n " (waiting) ."
            cnt=0
            while kill -0 $PID 2>/dev/null; do
                cnt=`expr $cnt + 1`
                if [ $cnt -gt 60 ]; then
                    # Waited 120 secs now, fail.
                    echo -n "Failed.. "
                    break
                fi
                sleep 2
                echo -n "."
                done
            fi
        echo -n " $inst"
        rm -f `pidfile $inst`
        rm -f `vtyfile $inst`
    fi
}

# Converts values from /etc/quagga/daemons to all-numeric values.
convert_daemon_prios()
{
        for name in $DAEMONS zebra vtysh_enable watchquagga_enable; do
          # First, assign the value set by the user to $value 
          eval value=\${${name}:0:3}

          # Daemon not activated or entry missing?
          if [ "$value" = "no" -o "$value" = "" ]; then value=0; fi

          # These strings parsed for backwards compatibility.
          if [ "$value" = "yes"  -o  "$value" = "true" ]; then
	     value=1;
          fi

          # Zebra is threatened special. It must be between 0=off and the first
      # user assigned value "1" so we increase all other enabled daemons' values.
          if [ "$name" != "zebra" -a "$value" -gt 0 ]; then value=`expr "$value" + 1`; fi

          # If e.g. name is zebra then we set "zebra=yes".
          eval $name=$value
        done
}

# Starts watchquagga for all wanted daemons.
start_watchquagga()
{
    local daemon_name
    local daemon_prio
    local found_one
    local daemon_inst

    # Start the monitor daemon only if desired.
    if [ 0 -eq "$watchquagga_enable" ]; then
        return
    fi

    # Check variable type
    if ! declare -p watchquagga_options | grep -q '^declare \-a'; then
      echo
      echo "ERROR: The variable watchquagga_options from /etc/quagga/debian.cnf must be a BASH array!"
      echo "ERROR: Please convert config file and restart!"
      exit 1
    fi

    # Which daemons have been started?
    found_one=0
    for daemon_name in $DAEMONS; do
        eval daemon_prio=\$$daemon_name
        if [ "$daemon_prio" -gt 0 ]; then
           eval "daemon_inst=\${${daemon_name}_instances//,/ }"
	   if [ -n "$daemon_inst" ]; then
	      for inst in ${daemon_inst}; do
		  eval "inst_disable=\${${daemon_name}_${inst}}"
		  if [ -z ${inst_disable} ] || [ ${inst_disable} != 0 ]; then
		      if check_daemon $daemon_name $inst; then
			  watchquagga_options+=("${daemon_name}-${inst}")
		      fi
		  fi
	      done
	   else
	       if check_daemon $daemon_name; then
		   watchquagga_options+=($daemon_name)
	       fi
           fi
           found_one=1
        fi
    done

    # Start if at least one daemon is activated.
    if [ $found_one -eq 1 ]; then
      echo -n "Starting Quagga monitor daemon:"
      start watchquagga
      echo "."
    fi
}

# Stopps watchquagga.
stop_watchquagga()
{
    echo -n "Stopping Quagga monitor daemon:"
    stop watchquagga
    echo "."
}

# Stops all daemons that have a lower level of priority than the given.
# (technically if daemon_prio >= wanted_prio)
stop_prio() 
{
        local wanted_prio
        local daemon_prio
        local daemon_list
        local daemon_inst
	local inst

        if [ -n "$2" ] && [[ "$2" =~ (.*)-(.*) ]]; then
	   daemon=${BASH_REMATCH[1]}
	   inst=${BASH_REMATCH[2]}
        else
	   daemon="$2"
        fi

        wanted_prio=$1
        daemon_list=${daemon:-$DAEMONS}

        echo -n "Stopping Quagga daemons (prio:$wanted_prio):"

        for prio_i in `seq 10 -1 $wanted_prio`; do
            for daemon_name in $daemon_list; do
	        eval daemon_prio=\${${daemon_name}:0:3}
		daemon_inst=""
                if [ $daemon_prio -eq $prio_i ]; then
		   eval "daemon_inst=\${${daemon_name}_instances//,/ }"
		   if [ -n "$daemon_inst" ]; then
			   for i in ${daemon_inst}; do
				if [ -n "$inst" ] && [ "$i" == "$inst" ]; then
				    stop "$daemon_name" "$inst"
			        elif [ x"$inst"  == x ]; then
				    stop "$daemon_name" "$i"
				fi
			   done
		    else
		       stop "$daemon_name"
		    fi
                fi
            done
        done

        echo "."
	if [ -z "$inst" ]; then
	# Now stop other daemons that're prowling, coz the daemons file changed
	    echo -n "Stopping other quagga daemons"
            if [ -n "$daemon" ]; then
		eval "file_list_suffix="$V_PATH"/"$daemon*""
	    else
		eval "file_list_suffix="$V_PATH/*""
	    fi
            for pidfile in $file_list_suffix.pid; do
		PID=`cat $pidfile 2>/dev/null`
		start-stop-daemon --stop --quiet --oknodo --pidfile "$pidfile"
		echo -n "."
		rm -rf "$pidfile"
            done
            echo "."

	    echo -n "Removing remaining .vty files"
	    for vtyfile in $file_list_suffix.vty; do
		rm -rf "$vtyfile"
	    done
            echo "."
	fi
}

# Starts all daemons that have a higher level of priority than the given.
# (technically if daemon_prio <= wanted_prio)
start_prio()
{
        local wanted_prio
        local daemon_prio
        local daemon_list
	local daemon_name
	local daemon_inst
	local inst

        if [ -n "$2" ] && [[ "$2" =~ (.*)-(.*) ]]; then
	   daemon=${BASH_REMATCH[1]}
	   inst=${BASH_REMATCH[2]}
        else
	   daemon="$2"
        fi
        
        wanted_prio=$1
        daemon_list=${daemon:-$DAEMONS}

        echo -n "Starting Quagga daemons (prio:$wanted_prio):"

        for prio_i in `seq 1 $wanted_prio`; do
            for daemon_name in $daemon_list; do
	        eval daemon_prio=\$${daemon_name}
		daemon_inst=""
                if [ $daemon_prio -eq $prio_i ]; then
		   eval "daemon_inst=\${${daemon_name}_instances//,/ }"
		   if [ -n "$daemon_inst" ]; then
                       if [ `echo "$daemon_inst" | wc -w` -gt ${MAX_INSTANCES} ]; then
                           echo "Max instances supported is ${MAX_INSTANCES}. Aborting"
                           exit 1
                       fi
	               # Check if we're starting again by switching from single instance
	               # to MI version
		       if started "$daemon_name"; then
			   PIDFILE=`pidfile $daemon_name`
			   start-stop-daemon \
			       --stop --quiet --oknodo \
			       --pidfile "$PIDFILE" \
			       --exec "$D_PATH/$daemon_name"

			   rm -f `pidfile $1`
			   rm -f `vtyfile $1`
		       fi

		       for i in ${daemon_inst}; do
			   if [ -n "$inst" ] && [ "$i" == "$inst" ]; then
			       start "$daemon_name" "$inst"
			   elif [ x"$inst" == x ]; then
			       start "$daemon_name" "$i"
			   fi
		       done
		   else
	               # Check if we're starting again by switching from
		       # single instance to MI version
		       eval "file_list_suffix="$V_PATH"/"$daemon_name-*""
		       for pidfile in $file_list_suffix.pid; do
			   start-stop-daemon --stop --quiet --oknodo --pidfile "$pidfile"
			   echo -n "."
			   rm -rf "$pidfile"
		       done
		       for vtyfile in $file_list_suffix.vty; do
			   rm -rf "$vtyfile"
		       done

		       start "$daemon_name"
		   fi
                fi
            done
        done
        echo "."
}

check_status()
{
    local daemon_name
    local daemon_prio
    local daemon_inst

    if [ -n "$1" ] && [[ "$1" =~ (.*)-(.*) ]]; then
	daemon=${BASH_REMATCH[1]}
	inst=${BASH_REMATCH[2]}
    else
	daemon="$1"
    fi

    daemon_list=${daemon:-$DAEMONS}

    # Which daemons have been started?
    for daemon_name in $daemon_list; do
        eval daemon_prio=\$$daemon_name
        if [ "$daemon_prio" -gt 0 ]; then
           eval "daemon_inst=\${${daemon_name}_instances//,/ }"
           if [ -n "$daemon_inst" ]; then
              for i in ${daemon_inst}; do
		  if [ -n "$inst" -a "$inst" = "$i" ]; then
                      started "$1" || return $?
		  elif [ -z "$inst" ]; then
                      started "$daemon_name-$i" || return $?
		  fi
              done
           else
               started "$daemon_name" || return $?
           fi
        fi
    done

    # All daemons that need to have been started are up and running
    return 0
}

#########################################################
#               Main program                            #
#########################################################

# Config broken but script must exit silently.
[ ! -r "$C_PATH/daemons" ] && exit 0

# Load configuration
. "$C_PATH/daemons"
. "$C_PATH/debian.conf"

# Read configuration variable file if it is present
[ -r /etc/default/quagga ] && . /etc/default/quagga

MAX_INSTANCES=${MAX_INSTANCES:=5}

# Set priority of un-startable daemons to 'no' and substitute 'yes' to '0'
convert_daemon_prios

if [ ! -d $V_PATH ]; then
    echo "Creating $V_PATH"
    mkdir -p $V_PATH
    chown quagga:quagga $V_PATH
    chmod 755 /$V_PATH
fi

if [ -n "$3" ]; then
   dmn="$2"-"$3"
elif [ -n "$2" ]; then
   dmn="$2"
fi

case "$1" in
    start)
        # Try to load this necessary (at least for 2.6) module.
        if [ -d /lib/modules/`uname -r` ] ; then
          echo "Loading capability module if not yet done."
          set +e; LC_ALL=C modprobe -a capability 2>&1 | egrep -v "(not found|Can't locate)"; set -e
        fi

        # Start all daemons
        cd $C_PATH/
        if [ "$2" != "watchquagga" ]; then
          start_prio 10 $dmn
        fi
        vtysh_b
        start_watchquagga
        ;;
        
    1|2|3|4|5|6|7|8|9|10)
        # Stop/start daemons for the appropriate priority level
        stop_prio $1
        start_prio $1
        vtysh_b
        ;;

    stop|0)
        # Stop all daemons at level '0' or 'stop'
        stop_watchquagga
        if [ "$dmn" != "watchquagga" ]; then
	  [ -n "${dmn}" ] && eval "${dmn/-/_}=0"
          stop_prio 0 $dmn
        fi

        if [ -z "$dmn" -o "$dmn" = "zebra" ]; then
          echo "Removing all routes made by zebra."
          ip route flush proto zebra
	else
	  [ -n "$dmn" ] && eval "${dmn/-/_}=0"
	  start_watchquagga
        fi
        ;;

    reload)
	# Just apply the commands that have changed, no restart necessary
        if [ -z "$ENABLE_RELOAD" ] || [ "$ENABLE_RELOAD" != "yes" ]; then
            echo "Reload is an experimental feature. Set ENABLE_RELOAD to yes in /etc/default/quagga."
            exit 1
        fi
	[ ! -x "$RELOAD_SCRIPT" ] && echo "quagga-reload script not available" && exit 0
	NEW_CONFIG_FILE="${2:-$C_PATH/Quagga.conf}"
	[ ! -r $NEW_CONFIG_FILE ] && echo "Unable to read new configuration file $NEW_CONFIG_FILE" && exit 1
	echo "Applying only incremental changes to running configuration from Quagga.conf"
	"$RELOAD_SCRIPT" --reload /etc/quagga/Quagga.conf
	;;

    status)
        check_status $dmn
        exit $?
        ;;

    restart|force-reload)
        $0 stop $dmn
        sleep 1
        $0 start $dmn
        ;;

    *)
        echo "Usage: /etc/init.d/quagga {start|stop|status|reload|restart|force-reload|<priority>} [daemon]"
        echo "       E.g. '/etc/init.d/quagga 5' would start all daemons with a prio 1-5."
	echo "       reload applies only modifications from the running config to all daemons."
	echo "       reload neither restarts starts any daemon nor starts any new ones."
        echo "       Read /usr/share/doc/quagga/README.Debian for details."
        exit 1
        ;;
esac

exit 0