Name:           slurm-bank
Version:        1.1.1.2
Release:        2%{?dist}
Summary:        SLURM Bank, a collection of wrapper scripts to do banking

Group:          System
License:        TBD
URL:            TBD
Source0:        slurm-bank-%{version}.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)

BuildRequires:  perl, bash, rsync, make
Requires:       slurm >= 2.2.0, perl, bash  

%description
SLURM Bank, a collection of wrapper scripts for implementing full
resource allocation to replace Maui and GOLD.

With the scripts we are able to provide a simple banking system where we
can deposit hours to an account. Users are associated to these accounts
from which they can use to run jobs. If users do not have an account or
if they do not have hours in their account then they cannot run jobs.

%prep
%setup -q

%build
make %{?_smp_mflags}


%install
rm -rf %{buildroot}
make install DESTDIR=%{buildroot}

mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/bash_completion.d
install -m 644 src/sbank.bash_completion $RPM_BUILD_ROOT%{_sysconfdir}/bash_completion.d/sbank

%clean
rm -rf %{buildroot}


%files
%defattr(-,root,root,-)
%doc doc/* AUTHORS README
%{_bindir}/*
%{_mandir}/*
%{_sysconfdir}/bash_completion.d

%changelog
* Wed Jun 08 2011 Jimmy Tang <jtang@tchpc.tcd.ie> - 1.1.1.2-2
Include bash completion when installing

* Wed May 18 2011 Jimmy Tang <jtang@tchpc.tcd.ie> - 1.0-1
Initial creation of spec file

