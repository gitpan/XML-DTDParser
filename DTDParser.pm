package XML::DTDParser;
require Exporter;
use FileHandle;
use strict;
our @ISA = qw(Exporter);

our @EXPORT = qw(ParseDTD FindDTDRoot);
our @EXPORT_OK = @EXPORT;

our $VERSION = 1.3;

my $name = '[\x41-\x5A\x61-\x7A\xC0-\xD6\xD8-\xF6\xF8-\xFF][#\x41-\x5A\x61-\x7A\xC0-\xD6\xD8-\xF6\xF8-\xFF0-9\xB7._:-]*';
my $nameX = $name . '[.?+*]*';

my $AttType = '(?:CDATA|ID|IDREF|IDREFS|ENTITY|ENTITIES|NMTOKEN|NMTOKENS|\(.*?\)|NOTATION ?\(.*?\))';
my $DefaultDecl = q{(?:#REQUIRED|#IMPLIED|(:?#FIXED ?)?(?:".*?"|'.*?'))};
my $AttDef = '('.$name.') ('.$AttType.')(?: ('.$DefaultDecl.'))?';

sub ParseDTD {
	my $xml = shift;
	my (%elements, %definitions);

	$xml =~ s/\s\s*/ /gs;

	while ($xml =~ s{<!ENTITY\s+(?:(%)\s*)?($name)\s+SYSTEM\s*"(.*?)"\s*>}{}io) {
		my ($percent, $entity, $include) = ($1,$2,$3);
		$percent = '&' unless $percent;
		my $definition;
		{
			local $/;
			my $IN;
			open $IN, "<$include" or die "Cannot open include file $include : $!\n";
			$definition = <$IN>;
			close $IN;
		}
		$definition =~ s/\s\s*/ /gs;
		$xml =~ s{\Q$percent$entity;\E}{$definition}g;
	}

	$xml =~ s{<!--.*?-->}{}gs;
	$xml =~ s{<\?.*?\?>}{}gs;

	while ($xml =~ s{<!ENTITY\s+(?:(%)\s*)?($name)\s*"(.*?)"\s*>}{}io) {
		my ($percent, $entity, $definition) = ($1,$2,$3);
		$percent = '&' unless $percent;
		$definitions{"$percent$entity"} = $definition;
	}

	{
		my $replacements = 0;
		1 while $replacements++ < 1000 and $xml =~ s{([&%]$name);}{(exists $definitions{$1} ? $definitions{$1} : "$1\x01;")}ge;
		die <<'*END*' if $xml =~ m{([&%]$name);};
Recursive <!ENTITY ...> definitions or too many entities! Only up to 1000 entity replacements allowed.
(An entity is something like &foo; or %foo;. They are defined by <!ENTITY ...> tag.)
*END*
	}
	undef %definitions;
	$xml =~ tr/\x01//d;

	while ($xml =~ s{<!ELEMENT\s+($name)\s*(\(.*?\))([?*+]?)\s*>}{}io) {
		my ($element, $children, $option) = ($1,$2,$3);
		$elements{$element}->{childrenSTR} = $children . $option;
		$children =~ s/\s//g;
		if ($children eq '(#PCDATA)') {
			$children = '#PCDATA';
		} else {
			$children = simplify_children( $children, $option);
		}

		$elements{$element}->{childrenARR} = [];
		foreach my $child (split ',', $children) {
			$child =~ s/([?*+])$//
				and $option = $1
				or $option = '!';
			$elements{$element}->{children}->{$child} = $option;
			push @{$elements{$element}->{childrenARR}}, $child
				unless $child eq '#PCDATA';
		}
		delete $elements{$element}->{childrenARR}
			if @{$elements{$element}->{childrenARR}} == 0
	}

	while ($xml =~ s{<!ELEMENT\s+($name)\s*(EMPTY|ANY)\s*>}{}io) {
		my ($element, $param) = ($1,$2);
		if (uc $param eq 'ANY') {
			$elements{$element}->{any} = 1;
		} else {
			$elements{$element} = {};
		}
	}
#=for comment
	while ($xml =~ s{<!ATTLIST\s+($name)\s+(.*?)\s*>}{}io) {
		my ($element, $attributes) = ($1,$2);
		die "<!ELEMENT $element ...> referenced by an <!ATTLIST ...> not found!\n"
			unless exists $elements{$element};
		while ($attributes =~ s/^\s*$AttDef//io) {
			my ($name,$type,$option,$default) = ($1,$2,$3);
			if ($option =~ /^#FIXED\s+["'](.*)["']$/i){
				$option = '#FIXED';
				$default = $1;
			} elsif ($option =~ /^["'](.*)["']$/i){
				$option = '#FIXED';
				$default = $1;
			}
			$elements{$element}->{attributes}->{$name} = [$type,$option,$default];
		}
	}
#=cut
#$xml = '';

	$xml =~ s/\s\s*/ /g;

	die "UNPARSED DATA:\n$xml\n\n"
		if $xml =~ /\S/;

	foreach my $element (keys %elements) {
		foreach my $child (keys %{$elements{$element}->{children}}) {
			if ($child eq '#PCDATA') {
				delete $elements{$element}->{children}->{'#PCDATA'};
				$elements{$element}->{content} = 1;
			} else {
				die "Element $child referenced by $element was not found!\n"
					unless exists $elements{$child};
				if (exists $elements{$child}->{parent}) {
					push @{$elements{$child}->{parent}}, $element;
				} else {
					$elements{$child}->{parent} = [$element];
				}
				$elements{$child}->{option} = $elements{$element}->{children}->{$child};
			}
		}
		if (scalar(keys %{$elements{$element}->{children}}) == 0) {
			delete $elements{$element}->{children};
		}
	}

	return \%elements;
}

sub or2and_children {
	my $children = $_[0];

}

sub flatten_children {
	my ( $children, $option ) = @_;

	if ($children =~ /\|/) {
		$children =~ s{[|,]}{?,}g;
		$children .= '?'
	}

	if ($option) {
		$children =~ s/,/$option,/g;
		$children .= $option;
	}

	return $children;
}

sub simplify_children {
	my ( $children, $option ) = @_;

	1 while $children =~ s{\(($nameX(?:[,|]$nameX)*)\)([?*+]*)}{flatten_children($1, $2)}geo;

	if ($option) {
		$children =~ s/,/$option,/g;
		$children .= $option;
	}

	foreach ($children) {
		s{\?\?}{?}g;
		s{\?\+}{*}g;
		s{\?\*}{*}g;
		s{\+\?}{*}g;
		s{\+\+}{+}g;
		s{\+\*}{*}g;
		s{\*\?}{*}g;
		s{\*\+}{*}g;
		s{\*\*}{*}g;
	}

	return $children;
}

sub FindDTDRoot {
	my $elements = shift;
	my @roots;
	foreach my $element (keys %$elements) {
		if (!exists $elements->{$element}->{parent}) {
			push @roots, $element;
			$elements->{$element}->{option} = '!';
		}
	}
	return @roots;
}

=head1 NAME

XML::DTDParser - quick&dirty DTD parser

Version 1.3

=head1 SYNOPSIS

  use XML::DTDParser qw(ParseDTD);

  open DTD, "<$dtdfile" or die "Cannot open $dtdfile : $!\n";
  my $DTDtext;
  { local $/;
	$DTDtext = <DTD>
  }
  close DTD;
  $DTD = ParseDTD $DTDtext;

=head1 DESCRIPTION

This module parses a DTD file and creates a data structure containing info about
all tags, their allowed parameters, children, parents, optionality etc. etc. etc.

Since I'm too lazy to document the structure, parse a DTD you need and print
the result to a file using Data::Dumper. The datastructure should be selfevident.

Note: The module should be able to parse just about anything, but it intentionaly looses some information.
Eg. if the DTD specifies that a tag should contain either CHILD1 or CHILD2 you only get that
CHILD1 and CHILD2 are optional. That is is the DTD contains
	<!ELEMENT FOO (BAR|BAZ)>
the result will be the same is if it contained
	<!ELEMENT FOO (BAR?,BAZ?)>

You get the original unparsed parameter list as well so if you need this information you may parse it yourself.

=head2 EXPORT

By default the module exports all (both) it's functions. If you only want one, or none
use either

	use XML::DTDParser qw(ParseDTD);
	or
	use XML::DTDParser qw();

=over 4

=item ParseDTD

	$DTD = ParseDTD $DTDtext;

Parses the $DTDtext and creates a data structure. If the $DTDtext contains some
<!ENTITY ... SYSTEM "..."> declarations those are read and parsed as needed.
The paths are relative to current directory.

The module currently doesn't support URLs here.

=item FindDTDRoot

	$DTD = ParseDTD $DTDtext;
	@roots = FindDTDRoot $DTD;

Returns all tags that have no parent. There could be several such tags defined by the DTD.
Especialy if it used some common includes.

=back

=head1 AUTHOR

Jenda@Krynicky.cz
http://Jenda.Krynicky.cz

=head1 COPYRIGHT

Copyright (c) 2002 Jan Krynicky <Jenda@Krynicky.cz>. All rights reserved.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut

