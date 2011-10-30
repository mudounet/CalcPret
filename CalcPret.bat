@rem = ' PERL for Windows NT - ccperl must be in search path
@echo off
ccperl %0 %1 %2 %3 %4 %5 %6 %7 %8 %9
goto endofperl
@rem ';

BEGIN {
	$0=~/^(.+[\\\/])[^\\\/]+[\\\/]*$/;
	my $physicalDir= $1 || "./";
	chdir($physicalDir);
}
use lib qw(lib);
use strict;
use warnings;
use Common;
use File::Copy;
use Data::Dumper;

use Storable qw(store retrieve thaw freeze);
use HTML::Template;
use XML::Simple;

use constant {
	PROGRAM_VERSION => '0.1',
};

INFO("Starting program (V ".PROGRAM_VERSION.")");

#########################################################
# loading of Configuration files
#########################################################
my $config = _loadConfig("./InitConfig/","CalcPret.config.xml",undef, KeyAttr => {}, ForceArray => qr/^(charge|apport|pret|revenu)$/);

my %output;

#########################################################
# Calcul du coût total de l'opération
#########################################################
$output{"Cout total"} = 0;

foreach my $charge (@{$config->{bien_immobilier}->{charge}}) {
	INFO "Traitement de la partie \"$charge->{name}\" du bien immobilier";
	
	$output{"Cout total"} += $charge->{montant};
}

#########################################################
# Mise en place des échéances des revenus
#########################################################


foreach my $charge (@{$config->{revenus}->{revenu}}) {
	INFO "Traitement de la partie \"$charge->{name}\" du bien immobilier";
	
	$output{echeances}[$charge->{echeance}]{revenu} += $charge->{montant};
}

#########################################################
# Calcul des échéances
#########################################################
my $capital_restant_du = $output{"Cout total"};
my $echeance = 0;
my $dernier_revenu = $output{echeances}[0]{revenu};

while($capital_restant_du > 0) {
	$echeance++;
	INFO "Calcul de l'echeance $echeance (".($echeance/12).") ...";

	####### Calcul du revenu à prendre en compte ########################
	$dernier_revenu = $output{echeances}[$echeance]{revenu} if($output{echeances}[$echeance]{revenu});
	if($capital_restant_du < $dernier_revenu) {
		$dernier_revenu = $capital_restant_du;
	}
	$output{echeances}[$echeance]{revenu} = $dernier_revenu;

	####### Calcul du montant des interets ##########################
	my $interets = 0;
	DEBUG "Montant des interets : $interets";
	
	####### Calcul du montant de l'assurance ########################
	$output{echeances}[$echeance]{assurance} = ($config->{assurance}->{taux} /1200) * $capital_restant_du;	
	DEBUG "Montant de l'assurance : $output{echeances}[$echeance]{assurance}";

	
	####### Calcul du capital remboursé #############################
	$output{echeances}[$echeance]{capital_rembourse} = $dernier_revenu - $interets - $output{echeances}[$echeance]{assurance};
	$capital_restant_du = $capital_restant_du - $output{echeances}[$echeance]{capital_rembourse};
	$output{echeances}[$echeance]{capital_a_rembourser} = $capital_restant_du;
}


print Dumper(\%output);

__END__
:endofperl
pause