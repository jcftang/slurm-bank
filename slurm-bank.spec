# Pass --without docs to rpmbuild if you don't want the documentation

Name:           slurm-bank
Version:        1.2
Release:        2%{?dist}
Summary:        SLURM Bank, a collection of wrapper scripts to do banking

Group:          System
License:        GPLv2
URL:            http://www.tchpc.tcd.ie/
Source0:        slurm-bank-%{version}.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)

BuildRequires:  perl, bash, rsync, make
Requires:       slurm >= 2.2.0, perl, bash  

%define path_settings HTMLDIR=%{_docdir}/%{name}-%{version}/html

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
make %{?_smp_mflags} CFLAGS="$RPM_OPT_FLAGS" \
	%{path_settings} \
	all %{!?_without_docs: docs}


%install
rm -rf %{buildroot}
make DESTDIR=%{buildroot} \
	%{path_settings} \
	install %{!?_without_docs: install-docs}
(find $RPM_BUILD_ROOT%{_bindir} -type f | sed -e s@^$RPM_BUILD_ROOT@@) > bin-man-doc-files

mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/bash_completion.d
install -m 644 src/sbank.bash_completion $RPM_BUILD_ROOT%{_sysconfdir}/bash_completion.d/sbank

%clean
rm -rf %{buildroot}


%files -f bin-man-doc-files
%defattr(-,root,root,-)
%doc AUTHORS README
%{_mandir}/*
%{_sysconfdir}/bash_completion.d
%if %{!?_without_docs:1}0
%doc html/*
%else
%doc doc/*
%endif

%changelog
* Wed Jun 08 2011 Jimmy Tang <jtang@tchpc.tcd.ie> - 1.1.1.2-2
Include bash completion when installing

* Wed May 18 2011 Jimmy Tang <jtang@tchpc.tcd.ie> - 1.0-1
Initial creation of spec file

