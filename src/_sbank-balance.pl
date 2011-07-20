#!/usr/bin/perl -w

# Emulate Gold's 'mybalance' script for SLURM
# 
# Assumes Enforced Limits, with GrpCPUMins set on Accounts (not users)
# 
# Specifically, the following must be set in slurm.conf:
#     AccountingStorageEnforce=limits
#     PriorityDecayHalfLife=0
#     PriorityUsageResetPeriod=NONE
# 
# Requires 'sacctmgr' and 'sshare'
# 

# TODO:
# - re-write using SLURM-Perl API


use strict;
use Getopt::Std;


my %acc_limits = ();
my %acc_usage = ();
my %user_usage = ();
my $thisuser = (getpwuid($<))[0];	# who's running the script
my $showallusers = 1;
my $showallaccs = 0;
my $clustername = "";
my $accountname = "";
my ($account, $user, $rawusage, $prev_acc);


#####################################################################
# subroutines
#####################################################################
sub usage() {
	print "Usage:\n";
	print "$0 [-h] [-c clustername] [-a accountname] [-A]\n";
	print "\t-h:\tshow this help message\n";
	print "\t-c:\tdisplay per cluster 'clustername' (defaults to the local cluster)\n";
	print "\t-a:\tdisplay unformatted balance of account 'accountname' (defaults to all accounts of the current user)\n";
	print "\t-u:\tdisplay only the current user's balances (defaults to all users in all accounts of the current user)\n";
	die   "\t-A:\tdisplay all accounts (defaults to all accounts of the current user; implies '-u')\n";
}

# format minutes as hours, with thousands comma separator
sub fmt_mins_as_hrs( $ ) {
	my $n = shift;

	return thous(sprintf("%.0f", $n/60));
}

# add commas
sub thous( $ ) {
	my $n = shift;
	1 while ($n =~ s/^(-?\d+)(\d{3})/$1,$2/);
	return $n;
}


#####################################################################
# get options
#####################################################################
my %opts;
getopts('huc:a:A', \%opts) || usage();

if (defined($opts{h})) {
	usage();
}

if (defined($opts{u})) {
	$showallusers = 0;
}

if (defined($opts{c})) {
	$clustername = $opts{c};
}

if (defined($opts{a})) {
	$accountname = $opts{a};
}

if (defined($opts{A})) {
	$showallaccs = 1;
}


#####################################################################
# start
# get the local clustername, or use the given clustername
#####################################################################

if ($clustername eq "") {
	open (SCONTROL, 'scontrol show config |')
		or die "$0: Unable to run scontrol: $!\n";

	while (<SCONTROL>) {
		if (/^ClusterName\s*=\s*(\S+)/) {
			$clustername = $1;
		}
	}

	close(SCONTROL);

	if ($clustername eq "") {
		die "$0: Unable to determine local cluster name via scontrol. Exiting..\n";
	}
}


#####################################################################
# run sacctmgr to find all Account limits from the list of 
# Assocations
#####################################################################

open (SACCTMGR, "sacctmgr list association cluster=$clustername format='Account,GrpCPUMins'" .
		" -p -n |")
	or die "$0: Unable to run sacctmgr: $!\n";

# GrpCPUMins are not in 'sshare'
while (<SACCTMGR>) {
	# format is "acct_string|nnnn|" where nnnn is the number of GrpCPUMins allocated
	if (/^([^|]+)\|([^|]*)/) {
		if ($2 ne "") {
			$acc_limits{"\U$1"} = sprintf("%.0f", $2);
		}
	}
}

close(SACCTMGR);


#####################################################################
# quick sanity check - did we find any GrpCPUMins ?
#####################################################################

if ((scalar keys %acc_limits) == 0) {
	die "$0: Unable to find any GrpCPUMins set on Accounts in cluster '$clustername' via sacctmgr. Exiting..\n";
}


#####################################################################
# if we need to show all users in our Accounts, then we have to
# run sshare twice - once to find all Accounts that I'm a part of,
# and secondly to dump all users in those accounts
#####################################################################

if ($showallusers) {
	# complex version:
	# show all users in only my Accounts

	my @my_accs = ();
	my $cluster_str = ($clustername ne "") ? "-M $clustername " : "";
	my $account_str = ($showallaccs) ? "-a " : "";

	$account = "";	# init to a value to stop perl warnings

	# only look to a specified account, rather than all
	# note we still need to run the loop below, to gather the account usage
	# values for all accounts
	if ($accountname ne "") {
		push @my_accs, $accountname;
	}


	# firstly grab the list of accounts that I'm a part of
	open (SSHARE, "sshare $account_str $cluster_str -hp |") or die "$0: Unable to run sacctmgr: $!\n";

	while (<SSHARE>) {
		# only show outputs for accounts we're part of
		if (/^\s*([^|]+)\|([^|]*)\|[^|]*\|[^|]*\|([^|]*)/) {
			$account      = "\U$1";
			$user         = $2;
			$rawusage     = $3;

			if ($user ne "") {
				# a user field present means we're part of the account, so add it;
				# unless we're only looking for a specific account
				if ($accountname eq "") {
					# build up list of my accounts
					push @my_accs, $account;
				}
			} elsif (exists($acc_limits{$account})) {
				# and store the account limits while we're here
				$acc_usage{$account} = sprintf("%.0f", $rawusage/60);
			}
		}
	}

	close(SSHARE);


	# display formatted output
	printf "%-10s %11s | %16s %11s | %13s %11s (CPU hrs)\n",
		"User", "Usage", "Account", "Usage", "Account Limit", "Available";
	printf "%10s %11s + %16s %11s + %13s %11s\n",
		"-"x10, "-"x11, "-"x16, "-"x11, "-"x13, "-"x11;


	# now, display all users from just those accounts
	open (SSHARE2, "sshare $cluster_str -aA " . (join ",",@my_accs) . " -hp 2>/dev/null |") or die "$0: Unable to run sacctmgr: $!\n";

	$prev_acc = "";

	while (<SSHARE2>) {
		if (/^\s*([^|]+)\|([^|]*)\|[^|]*\|[^|]*\|([^|]*)/) {
			if ($prev_acc ne "" && $account ne $prev_acc) {
				print "\n";
			}
			if ($account ne "") {
				$prev_acc = $account;
			}

			$account      = "\U$1";
			$user         = $2;
			$rawusage     = $3;

			next if($user eq "");

			# highlight current user
			if ($user eq $thisuser) {
				$user = "$user *";
			}

			# stop warnings if this account doesn't have a limit
			if (! exists($acc_limits{$account})) {
				$acc_limits{$account} = 0;
			}

			# stop warnings if this account doesn't have any usage
			if (! exists($acc_usage{$account})) {
				$acc_usage{$account} = 0;
			}

			printf "%-10s %11s | %16s %11s | %13s %11s\n",
				$user, fmt_mins_as_hrs(sprintf("%.0f", $rawusage/60)),
				$account, fmt_mins_as_hrs($acc_usage{$account}),
				fmt_mins_as_hrs($acc_limits{$account}),
				fmt_mins_as_hrs($acc_limits{$account} - $acc_usage{$account});
		}
	}

	close(SSHARE2);

} elsif ($accountname ne "") {
	# show only the balance for $accountname, unformatted

	my $cluster_str = ($clustername ne "") ? "-M $clustername " : "";

	$rawusage = "";	# init to a value to stop perl warnings

	# grab the usage for just that account
	open (SSHARE, "sshare $cluster_str -A $accountname -hp 2>/dev/null |") or die "$0: Unable to run sacctmgr: $!\n";

	# the first line of input has the values
	$_ = <SSHARE>;
	if (/^\s*([^|]+)\|([^|]*)\|[^|]*\|[^|]*\|([^|]*)/) {
		$account      = "\U$1";
		$user         = $2;
		$rawusage     = $3;

		if (exists($acc_limits{$account})) {
			# and store the account limits while we're here
			$acc_usage{$account} = sprintf("%.0f", $rawusage/60);
		}
	}

	close(SSHARE);

	if ($rawusage eq "") {
		die "$0: invalid account string '$accountname'\n";
	}

	# this is minutes - we need to convert to hours
	printf "%.0f\n", (($acc_limits{$account} - $acc_usage{$account})/60);

} else {
	# simple version:
	# only show my usage in the Accounts

	my $cluster_str = ($clustername ne "") ? "-M $clustername " : "";

	open (SSHARE, "sshare $cluster_str -hp |") or die "$0: Unable to run sacctmgr: $!\n";

	while (<SSHARE>) {
		# only show outputs for accounts we're part of
		if (/^\s*([^|]+)\|([^|]*)\|[^|]*\|[^|]*\|([^|]*)/) {
			$account      = "\U$1";
			$user         = $2;
			$rawusage     = $3;

			if (exists($acc_limits{$account}) && $user eq $thisuser) {
				$user_usage{$account} = sprintf("%.0f", $rawusage/60);
			} elsif (exists($acc_limits{$account})) {
				$acc_usage{$account} = sprintf("%.0f", $rawusage/60);
			}
		}
	}

	close(SSHARE);


	# display formatted output
	printf "%-10s %11s | %16s %11s | %13s %11s (CPU hrs)\n",
		"User", "Usage", "Account", "Usage", "Account Limit", "Available";
	printf "%10s %11s + %16s %11s + %13s %11s\n",
		"-"x10, "-"x11, "-"x16, "-"x11, "-"x13, "-"x11;

	foreach my $acc (sort keys %user_usage) {
		printf "%-10s %11s | %16s %11s | %13s %11s\n",
			$thisuser, fmt_mins_as_hrs($user_usage{$acc}),
			$acc, fmt_mins_as_hrs($acc_usage{$acc}),
			fmt_mins_as_hrs($acc_limits{$acc}),
			fmt_mins_as_hrs($acc_limits{$acc} - $acc_usage{$acc});
	}
}

