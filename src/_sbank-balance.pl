#!/usr/bin/perl -w

# Emulate Gold's 'mybalance' script for SLURM
# 
# Assumes Enforced Limits, with GrpCPUMins set on Accounts (not users)
# 
# Specifically, the following must be set in slurm.conf:
#     AccountingStorageEnforce=limits or AccountingStorageEnforce=safe
# 
# Note there is no longer a requirement to disable half-life decay, as in
# previous versions.
# 
# Requires 'sacctmgr' and 'sreport', and requires a SlurmDBD.
# 
# Note this is a re-write of the previous version, which used 'sshare' to
# obtain usage information. The 'sshare' command reads from local usage
# files, whereas as 'sreport' reads from the SlurmDBD. Specifically, 'sshare'
# values will decay if half-life decay is enabled, while 'sreport' values
# will not decay, and so give an actual usage.
# 

# TODO:
# - re-write using SLURM-Perl API


use strict;
use Getopt::Std;
use POSIX qw(strftime);


my %acc_limits = ();
my %acc_usage = ();
my %user_usage = ();
my %user_usage_per_acc = ();
my $thisuser = (getpwuid($<))[0];	# who is running the script
my $showallusers = 1;
my $showallaccs = 0;
my $clustername = "";
my $accountname = "";
my ($account, $user, $rawusage, $prev_acc);
my $sreport_start = "";
my $sreport_end   = "";
my $SREPORT_START_OFFSET = 94608000;	# 3 * 365 days, in seconds
my $SREPORT_END_OFFSET   = 172800;	# 2 days to avoid DST issues, in seconds


#####################################################################
# subroutines
#####################################################################
sub usage() {
	print "Usage:\n";
	print "$0 [-h] [-c clustername] [-a accountname] [-u] [-A] [-U username] [-s yyyy-mm-dd]\n";
	print "\t-h:\tshow this help message\n";
	print "\t-c:\tdisplay per cluster 'clustername' (defaults to the local cluster)\n";
	print "\t-a:\tdisplay unformatted balance of account 'accountname' (defaults to all accounts of the current user)\n";
	print "\t-u:\tdisplay only the current user's balances (defaults to all users in all accounts of the current user)\n";
	print "\t-A:\tdisplay all accounts (defaults to all accounts of the current user; implies '-u')\n";
	print "\t-U:\tdisplay information for the given username, instead of the current user\n";
	die   "\t-s:\treport usage starting from yyyy-mm-dd, instead of " . ($SREPORT_START_OFFSET / 365 / 86400) . " years ago\n";
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

# print headers for the output
sub print_headers() {
	printf "%-10s %9s | %14s %9s | %13s %9s (CPU hrs)\n",
		"User", "Usage", "Account", "Usage", "Account Limit", "Available";
	printf "%10s %9s + %14s %9s + %13s %9s\n",
		"-"x10, "-"x9, "-"x14, "-"x9, "-"x13, "-"x9;
}

# print the formatted values
sub print_values( $$$$$ ) {
	my $thisuser = shift;
	my $user_usage = shift;
	my $acc = shift;
	my $acc_usage = shift;
	my $acc_limit = shift;

	printf "%-10s %9s | %14s %9s | %13s %9s\n",
		$thisuser, fmt_mins_as_hrs($user_usage),
		$acc, fmt_mins_as_hrs($acc_usage),
		fmt_mins_as_hrs($acc_limit),
		fmt_mins_as_hrs($acc_limit - $acc_usage);
}


#####################################################################
# get options
#####################################################################
my %opts;
getopts('huU:c:a:As:', \%opts) || usage();

if (defined($opts{h})) {
	usage();
}

if (defined($opts{u})) {
	$showallusers = 0;
}

if (defined($opts{U})) {
	$thisuser = $opts{U};
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

if (defined($opts{s})) {
	unless ($opts{s} =~ /^\d{4}-\d{2}-\d{2}$/) { usage(); }

	$sreport_start = $opts{s};
	$sreport_end   = strftime "%Y-%m-%d", (localtime(time() + $SREPORT_END_OFFSET));
} else {
	$sreport_start = strftime "%Y-%m-%d", (localtime(time() - $SREPORT_START_OFFSET));
	$sreport_end   = strftime "%Y-%m-%d", (localtime(time() + $SREPORT_END_OFFSET));
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
# note that gives us the current active Accounts, which is useful
# because sreport will show usage from deleted accounts
#####################################################################

open (SACCTMGR, "sacctmgr list association cluster=$clustername format='Account,GrpCPUMins'" .
		" -p -n |")
	or die "$0: Unable to run sacctmgr: $!\n";

# GrpCPUMins are not in 'sreport'
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


#########################################################################################
# main code: there are a few different combinations:
# - Scenario #1 showallusers in a named account
# - Scenario #2 showallusers in every account, not just mine
# - Scenario #3 showallusers in all of my accounts
# - Scenario #4 show unformatted balance as a single figure, for the named account
# - Scenario #5 show only my usage, in all of my accounts
#########################################################################################


if ($showallusers && $accountname ne "") {
	#####################################################################
	# - Scenario #1 showallusers in a named account
	# only look to a specified account, rather than all
	# show all users in the given account
	#####################################################################

	my @my_accs = ();
	my $cluster_str = ($clustername ne "") ? "clusters=$clustername " : "";

	$account = "";	# init to a value to stop perl warnings

	# first obtain the full list of users for this account; sreport won't report
	# on them if they have no usage
	open (SACCTMGR, "sacctmgr list accounts accounts=$accountname withassoc -np $cluster_str format=User|") or die "$0: Unable to run sacctmgr: $!\n";

	while (<SACCTMGR>) {
		# only show outputs for accounts we're part of
		if (/^\s*([^|]+)\|/) {
			$user      = "$1";

			# put in a zero usage explicitly if the user hasn't run at all
			$user_usage_per_acc{"\U$accountname"}{$user} = 0;
		}
	}

	close(SACCTMGR);


	open (SREPORT, "sreport -t minutes -np cluster AccountUtilizationByUser account=$accountname start=$sreport_start end=$sreport_end $cluster_str |") or die "$0: Unable to run sreport: $!\n";


	# display formatted output
	print_headers();
	printf "\n";

	# get the usage values
	while (<SREPORT>) {
		# only show outputs for accounts we're part of
		if (/^\s*[^|]+\|([^|]*)\|([^|]*)\|[^|]*\|([^|]*)/) {
			$account      = "\U$1";
			$user         = $2;
			$rawusage     = $3;

			if (exists( $acc_limits{$account} ) && $user eq "") {
				# the first line is the overall account usage
				$acc_usage{$account} = sprintf("%.0f", $rawusage);
			} elsif (exists( $acc_limits{$account} )) {
				# then each subsequent line is an individual user
				# (already in alphabetical order)

				$user_usage_per_acc{$account}{$user} = $rawusage;
			}
		}
	}

	close(SREPORT);

	# now print the values, including those users with no usage
	foreach my $account (sort keys %user_usage_per_acc) {
		foreach my $user (sort keys %{ $user_usage_per_acc{$account} } ) {
			# then each subsequent line is an individual user
			# (already in alphabetical order)

			$rawusage = $user_usage_per_acc{$account}{$user};

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

			print_values($user, sprintf("%.0f", $rawusage), $account, $acc_usage{$account}, $acc_limits{$account});
		}
	}

} elsif ($showallusers && $showallaccs) {
	#####################################################################
	# - Scenario #2 showallusers in every account, not just mine
	# we need to show all users in ALL Accounts
	#####################################################################

	my @my_accs = ();
	my $cluster_str = ($clustername ne "") ? "clusters=$clustername " : "";

	$account = "";	# init to a value to stop perl warnings

	# first obtain the full list of users for all accounts; sreport won't report
	# on them if they have no usage
	open (SACCTMGR, "sacctmgr list accounts withassoc -np $cluster_str format=Account,User|") or die "$0: Unable to run sacctmgr: $!\n";

	while (<SACCTMGR>) {
		# only show outputs for accounts we're part of
		if (/^\s*([^|]+)\|([^|]+)\|/) {
			$account   = "\U$1";
			$user      = "$2";

			# put in a zero usage explicitly if the user hasn't run at all
			$user_usage_per_acc{$account}{$user} = 0;
		}
	}

	close(SACCTMGR);

	# display formatted output
	print_headers();
	printf "\n";


	# run the report for all named accounts (all the ones found by sacctmgr above)
	open (SREPORT, "sreport -t minutes -np cluster AccountUtilizationByUser account=" . join(',', sort(keys (%acc_limits))) . " start=$sreport_start end=$sreport_end $cluster_str |") or die "$0: Unable to run sreport: $!\n";

	# get the usage values
	while (<SREPORT>) {
		# only show outputs for accounts we're part of
		if (/^\s*[^|]+\|([^|]*)\|([^|]*)\|[^|]*\|([^|]*)/) {
			$account      = "\U$1";
			$user         = $2;
			$rawusage     = $3;

			if (exists( $acc_limits{$account} ) && $user eq "") {
				# the first line is the overall account usage
				$acc_usage{$account} = sprintf("%.0f", $rawusage);
			} elsif (exists( $acc_limits{$account} )) {
				# then each subsequent line is an individual user
				# (already in alphabetical order)

				$user_usage_per_acc{$account}{$user} = $rawusage;
			}
		}
	}

	close(SREPORT);

	# print the root account at the top, to be backwards-compatible
	if (exists ($user_usage_per_acc{"ROOT"})) {
		$account = "ROOT";

		foreach my $user (sort keys %{ $user_usage_per_acc{$account} } ) {
			# then each subsequent line is an individual user
			# (already in alphabetical order)

			$rawusage = $user_usage_per_acc{$account}{$user};

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

			print_values($user, sprintf("%.0f", $rawusage), $account, $acc_usage{$account}, $acc_limits{$account});
		}
	}

	# now print the values, including those users with no usage
	foreach my $account (sort keys %user_usage_per_acc) {
		next if ($account eq "ROOT");	# we've already done the root account

		# separate each account
		print "\n";

		foreach my $user (sort keys %{ $user_usage_per_acc{$account} } ) {
			# then each subsequent line is an individual user
			# (already in alphabetical order)

			$rawusage = $user_usage_per_acc{$account}{$user};

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

			print_values($user, sprintf("%.0f", $rawusage), $account, $acc_usage{$account}, $acc_limits{$account});
		}
	}



} elsif ($showallusers) {
	#####################################################################
	# - Scenario #3 showallusers in all of my accounts
	# if we need to show all users in all our Accounts, then we have to
	# run sacctmgr first, then sreport - first to find all Accounts that I'm a part of,
	# and secondly to dump all users in those accounts
	#####################################################################

	my @my_accs = ();
	my $cluster_str = ($clustername ne "") ? "clusters=$clustername " : "";

	$account = "";	# init to a value to stop perl warnings

	###############################################################################
	# sacctmgr #1 -- obtain the usage for this user, and also the list of all of their accounts
	###############################################################################

	# first obtain the full list of users for all accounts; sreport won't report
	# on them if they have no usage
	open (SACCTMGR, "sacctmgr list accounts withassoc -np $cluster_str format=Account,User|") or die "$0: Unable to run sacctmgr: $!\n";

	while (<SACCTMGR>) {
		# only show outputs for accounts we're part of
		if (/^\s*([^|]+)\|([^|]+)\|/) {
			$account   = "\U$1";
			$user      = "$2";

			# put in a zero usage explicitly if the user hasn't run at all
			$user_usage_per_acc{$account}{$user} = 0;
		}
	}

	close(SACCTMGR);

	# but only look at my accounts, not all accounts
	foreach my $acc (sort keys %user_usage_per_acc) {
		if (exists ($user_usage_per_acc{$acc}{$thisuser}) ) {
			push (@my_accs, $acc);
		} else {
			# remove the account
			delete $user_usage_per_acc{$acc};
		}
	}

	# display formatted output
	print_headers();


	###############################################################################
	# sreport #2 -- obtain the totals for each of the given accounts
	# we get the list of accounts by: "join(',', sort(@my_accs))"
	###############################################################################

	open (SREPORT, "sreport -t minutes -np cluster AccountUtilizationByUser account=" . join(',', sort(@my_accs)) . " start=$sreport_start end=$sreport_end $cluster_str |") or die "$0: Unable to run sreport: $!\n";

	$prev_acc = "";

	# get the usage values
	while (<SREPORT>) {
		# only show outputs for accounts we're part of
		if (/^\s*[^|]+\|([^|]*)\|([^|]*)\|[^|]*\|([^|]*)/) {
			$account      = "\U$1";
			$user         = $2;
			$rawusage     = $3;

			if (exists( $acc_limits{$account} ) && $user eq "") {
				# the first line is the overall account usage
				$acc_usage{$account} = sprintf("%.0f", $rawusage);
			} elsif (exists( $acc_limits{$account} )) {
				# then each subsequent line is an individual user
				# (already in alphabetical order)

				$user_usage_per_acc{$account}{$user} = $rawusage;
			}
		}
	}

	close(SREPORT);

	# now print the values, including those users with no usage
	foreach my $account (sort keys %user_usage_per_acc) {

		# separate each account
		print "\n";

		foreach my $user (sort keys %{ $user_usage_per_acc{$account} } ) {
			# then each subsequent line is an individual user
			# (already in alphabetical order)

			$rawusage = $user_usage_per_acc{$account}{$user};

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

			print_values($user, sprintf("%.0f", $rawusage), $account, $acc_usage{$account}, $acc_limits{$account});
		}
	}

} elsif ($accountname ne "") {
	#####################################################################
	# - Scenario #4 show unformatted balance as a single figure, for the named account
	# show only the balance for $accountname, unformatted
	#####################################################################

	#my $cluster_str = ($clustername ne "") ? "-M $clustername " : "";
	my $cluster_str = ($clustername ne "") ? "clusters=$clustername " : "";

	$rawusage = "";	# init to a value to stop perl warnings

	open (SREPORT, "sreport -t minutes -np cluster AccountUtilizationByUser account=$accountname start=$sreport_start end=$sreport_end $cluster_str |") or die "$0: Unable to run sreport: $!\n";

	while (<SREPORT>) {
		# only show outputs for accounts we're part of
		if (/^\s*[^|]+\|([^|]*)\|([^|]*)\|[^|]*\|([^|]*)/) {
			$account      = "\U$1";
			$user         = $2;
			$rawusage     = $3;

			# the account totals have an empty user column
			if ($user eq "") {
				$acc_usage{$account} = sprintf("%.0f", $rawusage);
				last;	# only one account
			}
		}
	}

	close(SREPORT);

	if ($rawusage eq "") {
		die "$0: invalid account string '$accountname'\n";
	}

	# this is minutes - we need to convert to hours
	printf "%.0f\n", (($acc_limits{$account} - $acc_usage{$account})/60);

} else {
	#####################################################################
	# - Scenario #5 show only my usage, in all of my accounts
	# only show my usage in the Accounts
	# run sacctmgr first, then sreport - first to find all Accounts that I'm a part of,
	# and secondly to dump all users in those accounts
	#####################################################################

	my @my_accs = ();
	my $cluster_str = ($clustername ne "") ? "clusters=$clustername " : "";

	###############################################################################
	# sacctmgr #1 -- obtain the usage for this user, and also the list of all of their accounts
	###############################################################################

	$account = "";	# init to a value to stop perl warnings

	open (SACCTMGR, "sacctmgr list accounts users=$thisuser withassoc -np $cluster_str format=Account|") or die "$0: Unable to run sacctmgr: $!\n";

	while (<SACCTMGR>) {
		# only show outputs for accounts we're part of
		if (/^\s*([^|]+)\|/) {
			$account      = "\U$1";

			if (exists( $acc_limits{$account} )) {
				# only report on accounts which are still live
				push (@my_accs, $account);

				# put in a zero value for users who haven't run at all, because
				# sreport won't show them
				$user_usage{$account} = 0;
			}
		}
	}

	close(SACCTMGR);


	###############################################################################
	# sreport #2 -- obtain the totals for each of the given accounts
	# we get the list of accounts by: "join(',', sort(@my_accs))"
	###############################################################################

	open (SREPORT, "sreport -t minutes -np cluster AccountUtilizationByUser account=" . join(',', sort(@my_accs)) . " start=$sreport_start end=$sreport_end $cluster_str |") or die "$0: Unable to run sreport: $!\n";

	while (<SREPORT>) {
		# only show outputs for accounts we're part of
		if (/^\s*[^|]+\|([^|]*)\|([^|]*)\|[^|]*\|([^|]*)/) {
			$account      = "\U$1";
			$user         = $2;
			$rawusage     = $3;

			# the account totals have an empty user column
			if ($user eq "") {
				$acc_usage{$account} = sprintf("%.0f", $rawusage);
			} elsif ($user eq $thisuser) {
				$user_usage{$account} = sprintf("%.0f", $rawusage);
			}
		}
	}

	close(SREPORT);
	# first obtain the full list of users for all accounts; sreport won't report
	# on them if they have no usage
	open (SACCTMGR, "sacctmgr list accounts withassoc -np $cluster_str format=Account,User|") or die "$0: Unable to run sacctmgr: $!\n";

	while (<SACCTMGR>) {
		# only show outputs for accounts we're part of
		if (/^\s*([^|]+)\|([^|]+)\|/) {
			$account   = "\U$1";
			$user      = "$2";

			# put in a zero usage explicitly if the user hasn't run at all
			$user_usage_per_acc{$account}{$user} = 0;
		}
	}

	close(SACCTMGR);


	# display formatted output
	print_headers();

	foreach my $acc (sort keys %user_usage) {
		# stop warnings if this account doesn't have a limit
		if (! exists($acc_limits{$acc})) {
			$acc_limits{$acc} = 0;
		}

		# stop warnings if this account doesn't have any usage
		if (! exists($acc_usage{$acc})) {
			$acc_usage{$acc} = 0;
		}

		print_values($thisuser, $user_usage{$acc}, $acc, $acc_usage{$acc}, $acc_limits{$acc});
	}
}

