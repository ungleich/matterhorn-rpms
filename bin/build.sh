#!/bin/bash 
# 
# Build rpms for specific spec file. Script follows spec file dependencies and
# install it first via other spec file, second via yum.  
# 

# install()
# {
#       spec file exists? {
#               for all needed packages in spec file call install(package)
#               returns if package is installed localy from spec file
#               compile, build, install rpm 
#       } else {
#               if package is not installed, then install it via yum
#       }
# }

# base switches
OS_BOTH=0

# base paths
specdir=$HOME/matterhorn-rpms/specs
rpmdir=$HOME/matterhorn-rpms/rpms
buildir=~/rpmbuild/BUILD/
sourcedir=~/rpmbuild/SOURCES/

# Set PATH, prefere default system paths
# default /usr/local is prefered, brake system rpm if compiled version is used
export PATH="/bin:/sbin:/usr/bin:/usr/sbin:$PATH"

# install ITEM1 means install ITEM2
eqarr="
librtmp-devel rtmpdump
cairo-gobject-devel cairo
/usr/bin/perl perl
"

# debug, be more verbose
debug="1"

# log 
log="1"
log_file=~/build.log


# reporting message
function message()
{
    echo "$(date +%F-%T) M: $@"
    [ "$log" = "1" ] && echo "$(date +%F-%T) M: $@" >> $log_file
}

# error, exit script
function error()
{
    echo "$(date +%F-%T) E: $@"
    [ "$log" = "1" ] && echo "$(date +%F-%T) E: $@" >> $log_file
    exit 1
}

# code execution, automatic error handler
function xeval()
{
    cmd=$@
    [ "$debug" = "1" ] && echo "$(date +%F-%T) C: $cmd"
    [ "$log" = "1" ] && echo "$(date +%F-%T) C: $cmd" >> $log_file
    eval $cmd || error "$cmd"
}

# help
function help()
{
cat <<EOF
$0 -h | -i | -t <TARGET_OS> | -p <PACKAGE>
    
    -h ... help
    -i ... init system for rpm building
    -t <TARGET_OS> define target os [rhel6, rhel7, both]
    -p <PACKAGE> ... make rpms for <PACKAGE> package

    $0 -i -t both
    $0 -t rhel6 -p ffmpeg
EOF
    exit 0
}

# install spec file
function install_specs()
{
    rpm="$1"
    basetarget="$2"
    specfile="$3"

    message "Install spec $specfile, rpm $rpm"

    line="$(yum list installed $rpm | egrep "^$rpm.*")" 
    message "Package list item from yum: $line"

    # application was installed locally? (via rpm from spec file)
    if echo "$line" | egrep "^$rpm.*(@/$rpm|installed)" >& /dev/null; then
	    message "Package $rpm installed from spec, skip package"
	    return 0
    elif [ -n "$line" ]; then
	    message "package $rpm installed via online repo, remove and install via specs"
	    # remove package without dependencies
	    #sudo yum remove -y $rpm
	    xeval "sudo rpm -e $rpm --nodeps"
    fi

    # Clear buildir
    rm -rf $buildir/* >& /dev/null

    # Get source(s)
    cd "$sourcedir"
    xeval "spectool --all --get-files $specfile"

    # Get dependencies
    cd "$specdir" 
    xeval "sudo yum-builddep -y $specfile"

    # Build package
    xeval "rpmbuild -bs $specfile"

    # Install package

    # based on eqarr
    local tmp="$(echo "$eqarr" | grep " $basetarget" | cut -d' ' -f1)"
    [ -n "$tmp" ] && toinst="$toinst ~/rpmbuild/RPMS/x86_64/*${tmp}*"
    # based on eqarr minus suffix devel
    tmp="${tmp%%-devel}"
    [ -n "$tmp" ] && toinst="$toinst ~/rpmbuild/RPMS/x86_64/*${tmp}*"
    xeval "sudo yum localinstall -y $toinst"
}

# Install required packages for running 
function init()
{
    # Install basic packages
    xeval "sudo yum install -y rpmdevtools.noarch rpmlint.noarch createrepo.noarch vim wget yum-utils"
    xeval "sudo yum install -y  gcc gcc-c++ make openssl-devel"
    xeval "sudo yum install -y  mock"

    # Setup build dirs
    cd ~
    xeval "rpmdev-setuptree"

    # Install EPEL repo
    #sudo yum localinstall --nogpgcheck \
    #  http://download.fedoraproject.org/pub/epel/6/i386/epel-release-6-8.noarch.rpm
    #if ! yum list installed epel-release.noarch >& /dev/null; then
    #    cd /tmp/
    #    xeval "wget http://dl.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm"
    #    xeval "sudo rpm -Uvh epel-release-6*.rpm"
    #fi
    xeval "sudo yum install epel-release"

    # Copy files to working directory
    cd "$sourcedir"
    xeval "cp $HOME/matterhorn-rpms/patch/* ./"

    # Download rpms
    if [ -f "$rpmdir/url.txt" ]; then
            cd $rpmdir
            xeval "wget -i $rpmdir/url.txt"
    fi
    # If creating for both os
    if [ -n ${OS_BOTH} ]; then
        if [ -f "$rpmdir7/url.txt" ]; then
                cd $rpmdir7
                xeval "wget -i $rpmdir7/url.txt"
        fi
    fi

    # Initialize mock
    case "${os}" in
        rhel6)  mock -r epel-6-x86_64 --init
                ;;
        rhel7)  mock -r epel-7-x86_64 --init
                ;;
        both)   mock -r epel-6-x86_64 --init
                mock -r epel-7-x86_64 --init
                ;;
    esac
}

# main function, the base of recursion
function main() 
{
    local target="$1"
    local tmptar=""

    message "Start with target $target"

    # lookup eqarr 
    tmptar="$(echo "$eqarr" | grep "^$target " | cut -d' ' -f2)"
    if [ -n "$tmptar" ]; then
       message "Target found in eqarr => $target = $tmptar"
       target="$tmptar"
    fi

    # remove -devel suffix (devel version goes from its original package)
    local basetarget="${target%%-devel}"
    # add suffix .spec
    local specfile="$specdir/$basetarget.spec"

    # spec file exists?
    if [ -f "$specfile" ]; then
        message "Specfile $specfile exists, following dependencies"
        # Solve dependencies via rekursion calls
        breqs="$($rpmspec -q --buildrequires $specfile)"
        rc=$?
        [ "$rc" != "0" ] && error "rpmspec -q --buildrequires returns $rc"
        for breq in $(echo "$breqs" | cut -d' ' -f1); do
            message "Run main $breq (dependence of $(basename $specfile))"
            main $breq
        done
        install_specs $target $basetarget $specfile 
    # package is not installed
    elif ! yum list installed $target >& /dev/null; then
        # is package in online repo?
        if yum list $target >& /dev/null; then
            message "Install target $target from online repo"
            xeval "sudo yum install -y -q $target"
        # is package in local directory
        elif ls $rpmdir/$target* >& /dev/null; then
            message "Install target $target from local directory"
            xeval "sudo yum localinstall -y -q $rpmdir/$target*"
        # no source, can not install
        else
            error "There is no source to install $target"
        fi
    else
        message "Target $target is installed, skipped"
    fi

    # If OS_BOTH switch is set
    if [ ${OS_BOTH} -eq 1 ]; then
        os="rhel7"
        # add suffix .spec
        local specfile7="$specdir7/$basetarget.spec"

        # spec file exists?
        if [ -f "$specfile7" ]; then
            message "Specfile $specfile7 exists, following dependencies"
            # Solve dependencies via rekursion calls
            breqs="$($rpmspec -q --buildrequires $specfile7)"
            rc=$?
            [ "$rc" != "0" ] && error "rpmspec -q --buildrequires returns $rc"
            for breq in $(echo "$breqs" | cut -d' ' -f1); do
                message "Run main $breq (dependence of $(basename $specfile7))"
                main $breq
            done
            install_specs $target $basetarget $specfile7 
        # package is not installed
        elif ! yum list installed $target >& /dev/null; then
            # is package in online repo?
            if yum list $target >& /dev/null; then
                message "Install target $target from online repo"
                xeval "sudo yum install -y -q $target"
            # is package in local directory
            elif ls $rpmdir/$target* >& /dev/null; then
                message "Install target $target from local directory"
                xeval "sudo yum localinstall -y -q $rpmdir/$target*"
            # no source, can not install
            else
                error "There is no source to install $target"
            fi
        else
            message "Target $target is installed, skipped"
        fi
    fi
}

# path to rpmspec tool (package rpm contains rpmspec) 
if [ -f "/usr/bin/rpmspec" ]; then
    rpmspec="/usr/bin/rpmspec"
elif [ -f "/usr/local/bin/rpmspec" ]; then
    rpmspec="/usr/local/bin/rpmspec"
else
    error "Can not find tool rpmspec"
fi

# parse input arguments
while [ "$#" != "0" ]; do
    case "$1" in
        -t) shift
            os="$1"
            ;;
        -i) init=1
            ;;
        -p) shift
            target="$1"
            ;;
        *)  help
            ;;
    esac
    shift
done

# change directories for centos7
#if egrep 'CentOS Linux release 7\.' /etc/redhat-release >& /dev/null; then
#    specdir="${specdir}-centos7"
#    rpmdir="${rpmdir}-centos7"
#fi

# check if os is valide
case "${os}" in
    rhel6)  specdir="${specdir}"
            rpmdir="${rpmdir}"
            ;;
    rhel7)  specdir="${specdir}-centos7"
            rpmdir="${rpmdir}-centos7"
            ;;
    both)   OS_BOTH=1
            specdir7="${specdir}-centos7"
            rpmdir7="${rpmdir}-centos7"
            os="rhel6"
            ;;
    *)      help
esac

[ ${init} -eq 1 ] && init && exit

# target is required
[ -z "$target" ] && help

# print variables
message "rpmspec=$rpmspec specdir=$specdir rpmdir=$rpmdir os=${os}"

# start iteration #1
main $target
