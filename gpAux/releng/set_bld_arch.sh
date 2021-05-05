# ----------------------------------------------------------------------
# Define ARCH values
# ----------------------------------------------------------------------

case "`uname -s`" in
    Linux)
    if [ -f /etc/redhat-release ]; then
        case "`cat /etc/redhat-release`" in
            *)
            BLD_ARCH_HOST="rhel`cat /etc/redhat-release | sed -e 's/CentOS Linux/RedHat/' -e 's/Red Hat Enterprise Linux/RedHat/' -e 's/WS//' -e 's/Server//' -e 's/Client//' | awk '{print $3}' | awk -F. '{print $1}'`_`uname -p | sed -e s/i686/x86_32/`"
            ;;
        esac
    fi
    *)
    BLD_ARCH_HOST="BLD_ARCH_unknown"
    ;;
esac

echo ${BLD_ARCH_HOST}
