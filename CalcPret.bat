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
# Déduction des apports personnels
#########################################################
$output{"Apports personnels"} = 0;
foreach my $charge (@{$config->{apports}->{apport}}) {
	INFO "Deduction de l'apport \"$charge->{name}\" du bien immobilier";
	
	$output{"Apports personnels"} += $charge->{montant};
}

#########################################################
# Mise en place des échéances des revenus
#########################################################
my @echeances;
foreach my $charge (@{$config->{revenus}->{revenu}}) {
	INFO "Traitement de la partie \"$charge->{name}\" du bien immobilier";
	
	$echeances[$charge->{echeance}]{montant} += $charge->{montant};
}

#########################################################
# Calcul des différents prêts
#########################################################
my %prets;
my $pret_sans_montant_ref = undef;
my $restant_pret = $output{"Cout total"} - $output{"Apports personnels"};
foreach my $pret (@{$config->{prets}->{pret}}) {
	INFO "Calcul des parametres du pret \"$pret->{name}\"";
	my %param_pret = ( nom => $pret->{name}, capital => $pret->{montant}, mensualites => $pret->{mensualites}, echeances => $pret->{echeances}, taux => $pret->{taux}, periodes => $pret->{periodes}->{mensualite});
	if(ref($pret->{montant}) eq "" && $pret->{montant} > 0) {
		DEBUG "Pret renseigne trouve";
		
		%param_pret = completer_donnees_pret(\%param_pret, $config->{assurance}->{taux});
		$restant_pret -= $param_pret{capital}; 
		
		$prets{$pret->{name}} = \%param_pret;
	} else {
		if(!$pret_sans_montant_ref) {
			DEBUG "Pret sans montant detecte";
			$pret_sans_montant_ref = \%param_pret;
		}
		else {
			LOGDIE "Plusieurs prets sans montant detectes."
		}
	}
}

if($pret_sans_montant_ref) {
	INFO "Calcul du montant a partir des autres prets.";
	$pret_sans_montant_ref->{capital} = $restant_pret;
}

#########################################################
# Calcul des échéances
#########################################################
my @echeances_autres_prets;
my %calculs_prets;
$calculs_prets{synthese}{interets} = 0;
$calculs_prets{synthese}{assurance} = 0;
$calculs_prets{synthese}{echeances} = 0;
$calculs_prets{synthese}{capital} = 0;
while (my ($nom_pret, $pret) = each(%prets)){
    DEBUG "Calcul des echeances du pret \"".$nom_pret."\"";
	
	my %pret_detail;
	if($pret->{periodes}) {
		foreach my $periode (@{$pret->{periodes}}) {
			%pret_detail = calcul_detail_echeances($pret, echeances_autre_pret => \@echeances_autres_prets, periode => $periode, calcul_anciennes_periodes => \%pret_detail );
		}
	}
	else {
		%pret_detail = calcul_detail_echeances($pret, echeances_autre_pret => \@echeances_autres_prets);
	}
	
	$calculs_prets{synthese}{capital} += $pret_detail{synthese}{capital};
	$calculs_prets{synthese}{interets} += $pret_detail{synthese}{interets};
	$calculs_prets{synthese}{assurance} += $pret_detail{synthese}{assurance};
	$calculs_prets{synthese}{echeances} = $pret_detail{synthese}{echeances} if $pret_detail{synthese}{echeances} > $calculs_prets{synthese}{echeances};
	$calculs_prets{prets}{$nom_pret} = \%pret_detail;
}

if($pret_sans_montant_ref ) {
	LOGDIE "revenus non renseignes et necessaires" unless ref $config->{revenus}->{revenu} eq "ARRAY";
	my $nom_pret = $pret_sans_montant_ref->{nom};
	my %pret_detail = calcul_detail_echeances($pret_sans_montant_ref, enveloppe_mensualites => $config->{revenus}->{revenu}, echeances_autre_pret => \@echeances_autres_prets);
	
	$calculs_prets{synthese}{capital} += $pret_detail{synthese}{capital};
	$calculs_prets{synthese}{interets} += $pret_detail{synthese}{interets};
	$calculs_prets{synthese}{assurance} += $pret_detail{synthese}{assurance};
	$calculs_prets{synthese}{echeances} = $pret_detail{synthese}{echeances} if $pret_detail{synthese}{echeances} > $calculs_prets{synthese}{echeances};
	$calculs_prets{prets}{$nom_pret} = \%pret_detail;
}

$calculs_prets{echeances} = \@echeances_autres_prets;

open FILE,">recapitulatif.txt";
print FILE Dumper(\%calculs_prets);
close FILE;

ecrire_sortie_html (\%calculs_prets, "resultats.html");


############################################################################
# Fonctions de calcul
############################################################################
sub calcul_detail_echeances {
	my ($param_pret_ref, %options) = @_;
	my %param_pret = %$param_pret_ref;

	my (%donnees_pret, %autres_parametres_prets, %anciennes_periodes);
	%autres_parametres_prets = %{$options{periode}} if $options{periode};
	%anciennes_periodes = %{$options{calcul_anciennes_periodes}} if $options{calcul_anciennes_periodes};
	
	my $echeances_autres_prets_ref = $options{echeances_autre_pret};
	
	my $capital_restant_du;

	if (%anciennes_periodes) {
		%donnees_pret = %anciennes_periodes;
		$capital_restant_du = $donnees_pret{echeances}[$donnees_pret{synthese}{echeances}]{capital_a_rembourser};
	}
	else {
		$capital_restant_du = $param_pret{capital};
		$donnees_pret{synthese}{capital} = $capital_restant_du;
		$donnees_pret{synthese}{assurance} = 0;
		$donnees_pret{synthese}{interets} = 0;
		$donnees_pret{synthese}{echeances} = 0;
		$donnees_pret{synthese}{taux} = $param_pret{taux};
		$donnees_pret{echeances}[0]{capital_a_rembourser} = $capital_restant_du;
	}
	
	
	my $montant_echeance = $param_pret{mensualites};
	$montant_echeance = $autres_parametres_prets{montant} if $autres_parametres_prets{montant};

	my $echeances_periode = 0;
	my $periode_calculee;
	my $montant_echeance_dynamique = $options{enveloppe_mensualites}->[0]{montant} if $options{enveloppe_mensualites}->[0]{montant};
	while($capital_restant_du > 0 && !$periode_calculee) {
		
		$echeances_periode++;
		$periode_calculee = 1 if ($autres_parametres_prets{echeances} && $echeances_periode >= $autres_parametres_prets{echeances});
		
		my $echeance = $donnees_pret{synthese}{echeances} + $echeances_periode;

		
		
		DEBUG "Calcul de l'echeance $echeance (".($echeance/12).") ...";

		####### Calcul du montant des interets ##########################
		my $interets = ($param_pret{taux}/1200) * $capital_restant_du;
		
		DEBUG "Montant des interets : $interets";
		
		####### Calcul du montant de l'assurance ########################
		my $assurance = ($config->{assurance}->{taux} /1200) * $capital_restant_du;	

		DEBUG "Montant de l'assurance : $assurance";

		####### Calcul du revenu à prendre en compte ########################
		my $montant_echeance_calcule;
		if($autres_parametres_prets{montant_hors_charges}) {
			$montant_echeance_calcule = $autres_parametres_prets{montant_hors_charges} + $interets + $assurance;
		}
		elsif ($montant_echeance_dynamique) {
			$montant_echeance_dynamique = $montant_echeance_dynamique = $options{enveloppe_mensualites}->[$echeance]{montant} if $options{enveloppe_mensualites}->[$echeance]{montant};
			$montant_echeance_calcule = $montant_echeance_dynamique - $echeances_autres_prets_ref->[$echeance];
		}
		elsif(!$montant_echeance) {
			LOGDIE "ERREUR DANS LE PROGRAMME";
		}
		else {
			$montant_echeance_calcule = $montant_echeance;
		}
		
		$echeances_autres_prets_ref->[$echeance] = $echeances_autres_prets_ref->[$echeance] ? $echeances_autres_prets_ref->[$echeance] + $montant_echeance_calcule : $montant_echeance_calcule;
		$donnees_pret{echeances}[$echeance]{montant_echeance} = $montant_echeance_calcule;
	
	
		####### Calcul du capital remboursé #############################
		if($capital_restant_du < $montant_echeance_calcule) {
			$donnees_pret{echeances}[$echeance]{capital_rembourse} = $capital_restant_du;
		}
		else {
			$donnees_pret{echeances}[$echeance]{capital_rembourse} = $montant_echeance_calcule - $interets - $assurance;
		}
		$donnees_pret{echeances}[$echeance]{assurance} = $assurance;
		$donnees_pret{echeances}[$echeance]{interets} = $interets;
		$capital_restant_du = $capital_restant_du - $donnees_pret{echeances}[$echeance]{capital_rembourse};
		
		
		$donnees_pret{echeances}[$echeance]{capital_a_rembourser} = $capital_restant_du;
		###################################
		$donnees_pret{synthese}{interets} += $interets;
		$donnees_pret{synthese}{assurance} +=$assurance;
	}
	
	$donnees_pret{synthese}{echeances} = $donnees_pret{synthese}{echeances} + $echeances_periode;
	return %donnees_pret;
}

sub completer_donnees_pret {
	my ($param_pret, $taux_assurance) = @_;
	
	DEBUG ref($param_pret->{periodes});
	if((ref($param_pret->{periodes}) eq "ARRAY") && $param_pret->{capital}) {
		return %$param_pret;
	}
	
	if(!($param_pret->{taux} && $param_pret->{capital} && $param_pret->{echeances})) {
		LOGDIE "Donnees incompletes : ".Dumper($param_pret);
	}
	elsif (!$param_pret->{mensualite}) {
		return calc_mensualites($param_pret, $taux_assurance);	
	} else {
		LOGDIE "Mode de calcul non défini.";
	}
}

sub calc_mensualites {
	my ($param_pret, $taux_assurance) = @_;
	$taux_assurance = 0 unless $taux_assurance;
	my $taux = ($param_pret->{taux} + $taux_assurance) / 1200;
	my $capital = $param_pret->{capital};
	my $echeances = $param_pret->{echeances};
	$param_pret->{mensualites} = $capital * $taux / ( 1 - 1/((1 + $taux)**($echeances)));
	return %$param_pret;
}

sub ecrire_sortie_html {
	my ($resultats_prets, $fichier) = @_;
	
	
		open OUTFILE, ">$fichier";
	
	my $template_file = 'InitConfig/template.tmpl';
	my $mainTemplate = HTML::Template -> new( die_on_bad_params => 1, filename => $template_file );
			
	my @recap_liste_prets;
	
	##############################################
	##### Récapitulatif des prêts
	##############################################
	
	while(my ($nom, $pret) = each(%{$resultats_prets->{prets}})) {
		INFO "$nom";
		
		my %proprietes;
		$proprietes{NOM_PRET} = $nom;
		
		$proprietes{TAUX} = $pret->{synthese}{taux};
		$proprietes{CAPITAL_EMPRUNTE} = $pret->{synthese}{capital};
		
		$proprietes{TOTAL_DUREE} = $pret->{synthese}{echeances};
		$proprietes{TOTAL_ASSURANCE} = tronquer_chiffre($pret->{synthese}{assurance});
		$proprietes{TOTAL_TAUX_INTERET} = tronquer_chiffre($pret->{synthese}{interets});
		$proprietes{TOTAL} = tronquer_chiffre($pret->{synthese}{interets} + $pret->{synthese}{assurance});

		push(@recap_liste_prets, \%proprietes);
	}
	
	$mainTemplate->param(PRETS_RECAP => \@recap_liste_prets);
	$mainTemplate->param(TOTAL_CAPITAL => $resultats_prets->{synthese}{capital});
	$mainTemplate->param(TOTAL_DUREE => $resultats_prets->{synthese}{echeances});
	$mainTemplate->param(TOTAL_ASSURANCE => tronquer_chiffre($resultats_prets->{synthese}{assurance}));
	$mainTemplate->param(TOTAL_TAUX_INTERET => tronquer_chiffre($resultats_prets->{synthese}{interets}));
	$mainTemplate->param(TOTAL => tronquer_chiffre($resultats_prets->{synthese}{interets} + $resultats_prets->{synthese}{assurance}));
	
	##############################################
	##### Echéancier général
	##############################################
	
	my @liste_echeances;
	my $echeance_trouve = 1;
	my $echeance = 0;
	while($echeance_trouve) {
		$echeance++;
		my %echeance;

		$echeance{ECHEANCE_RECAP} = 0;
		
		$echeance_trouve = 0;
		
		$echeance{LABEL} = $echeance;
		$echeance{MONTANT_ECHEANCE} = 0;
		$echeance{ASSURANCE} = 0;
		$echeance{INTERETS} = 0;
		$echeance{CAPITAL_RESTANT} = 0;
		$echeance{CAPITAL_REMBOURSE} = 0;
		while(my ($nom, $pret) = each(%{$resultats_prets->{prets}})) {
			my $donnees = $pret->{echeances}[$echeance];
						
			if($donnees) {
				$echeance_trouve = 1;
				$echeance{INTERETS} += $donnees->{interets};
				$echeance{ASSURANCE} += $donnees->{assurance};
				$echeance{CAPITAL_REMBOURSE} += $donnees->{capital_rembourse};
				$echeance{MONTANT_ECHEANCE} += $donnees->{montant_echeance};
				$echeance{CAPITAL_RESTANT} += $donnees->{capital_a_rembourser};
			}
		}

		DEBUG "Calcul de l'échéance $echeance";
		if(!$echeance_trouve) {
			$echeance{LABEL} = "";
			$echeance{ECHEANCE_RECAP} = 1;
		}
		push(@liste_echeances, \%echeance);
	}
	
	$mainTemplate->param(ECHEANCES_GLOBALES => \@liste_echeances);


	INFO "Generating $fichier";
	print OUTFILE $mainTemplate->output;
	close OUTFILE;
}

sub tronquer_chiffre {
	my ($valeur) = @_;
	return sprintf("%.2f", $valeur);
}

__END__
:endofperl
pause