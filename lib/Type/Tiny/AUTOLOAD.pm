use strict;
use warnings;

package Type::Tiny;

sub validate
{
	my $self = shift;
	
	return undef if ($self->{compiled_type_constraint} ||= $self->_build_compiled_check)->(@_);
	
	local $_ = $_[0];
	return $self->get_message(@_);
}

sub validate_explain
{
	my $self = shift;
	my ($value, $varname) = @_;
	$varname = '$_' unless defined $varname;
	
	return undef if $self->check($value);
	
	if ($self->has_parent)
	{
		my $parent = $self->parent->validate_explain($value, $varname);
		return [ sprintf('"%s" is a subtype of "%s"', $self, $self->parent), @$parent ] if $parent;
	}
	
	my $message = sprintf(
		'%s%s',
		$self->get_message($value),
		$varname eq q{$_} ? '' : sprintf(' (in %s)', $varname),
	);
	
	if ($self->is_parameterized and $self->parent->has_deep_explanation)
	{
		my $deep = $self->parent->deep_explanation->($self, $value, $varname);
		return [ $message, @$deep ] if $deep;
	}
	
	return [ $message, sprintf('"%s" is defined as: %s', $self, $self->_perlcode) ];
}

my $b;
sub _perlcode
{
	my $self = shift;
	
	local our $AvoidCallbacks = 1;
	return $self->inline_check('$_')
		if $self->can_be_inlined;
	
	$b ||= do {
		require B::Deparse;
		my $tmp = "B::Deparse"->new;
		$tmp->ambient_pragmas(strict => "all", warnings => "all") if $tmp->can('ambient_pragmas');
		$tmp;
	};
	
	my $code = $b->coderef2text($self->constraint);
	$code =~ s/\s+/ /g;
	return "sub $code";
}

sub _instantiate_moose_type
{
	my $self = shift;
	my %opts = @_;
	require Moose::Meta::TypeConstraint;
	return "Moose::Meta::TypeConstraint"->new(%opts);
}

sub _build_moose_type
{
	my $self = shift;
	
	my $r;
	if ($self->{_is_core})
	{
		require Moose::Util::TypeConstraints;
		$r = Moose::Util::TypeConstraints::find_type_constraint($self->name);
		$r->{"Types::TypeTiny::to_TypeTiny"} = $self;
		Scalar::Util::weaken($r->{"Types::TypeTiny::to_TypeTiny"});
	}
	else
	{
		# Type::Tiny is more flexible than Moose, allowing
		# inlined to return a list. So we need to wrap the
		# inlined coderef to make sure Moose gets a single
		# string.
		#
		my $wrapped_inlined = sub {
			shift;
			$self->inline_check(@_);
		};
		
		my %opts;
		$opts{name}       = $self->qualified_name     if $self->has_library && !$self->is_anon;
		$opts{parent}     = $self->parent->moose_type if $self->has_parent;
		$opts{constraint} = $self->constraint         unless $self->_is_null_constraint;
		$opts{message}    = $self->message            if $self->has_message;
		$opts{inlined}    = $wrapped_inlined          if $self->has_inlined;
		
		$r = $self->_instantiate_moose_type(%opts);
		$r->{"Types::TypeTiny::to_TypeTiny"} = $self;
		$self->{moose_type} = $r;  # prevent recursion
		$r->coercion($self->coercion->moose_coercion) if $self->has_coercion;
	}
		
	return $r;
}

sub _build_mouse_type
{
	my $self = shift;
	
	my %options;
	$options{name}       = $self->qualified_name     if $self->has_library && !$self->is_anon;
	$options{parent}     = $self->parent->mouse_type if $self->has_parent;
	$options{constraint} = $self->constraint         unless $self->_is_null_constraint;
	$options{message}    = $self->message            if $self->has_message;
		
	require Mouse::Meta::TypeConstraint;
	my $r = "Mouse::Meta::TypeConstraint"->new(%options);
	
	$self->{mouse_type} = $r;  # prevent recursion
	$r->_add_type_coercions(
		$self->coercion->freeze->_codelike_type_coercion_map('mouse_type')
	) if $self->has_coercion;
	
	return $r;
}

sub coercibles
{
	my $self = shift;
	$self->has_coercion ? $self->coercion->_source_type_union : $self;
}

sub _build_util {
	my ($self, $func) = @_;
	Scalar::Util::weaken( my $type = $self );
	
	if ( $func eq 'grep' || $func eq 'first' || $func eq 'any' || $func eq 'all' || $func eq 'assert_any' || $func eq 'assert_all' ) {
		my ($inline, $compiled);
		
		if ( $self->can_be_inlined ) {
			$inline = $self->inline_check('$_');
		}
		else {
			$compiled = $self->compiled_check;
			$inline   = '$compiled->($_)';
		}
		
		if ( $func eq 'grep' ) {
			return eval "sub { grep { $inline } \@_ }";
		}
		elsif ( $func eq 'first' ) {
			return eval "sub { for (\@_) { return \$_ if ($inline) }; undef; }";
		}
		elsif ( $func eq 'any' ) {
			return eval "sub { for (\@_) { return !!1 if ($inline) }; !!0; }";
		}
		elsif ( $func eq 'assert_any' ) {
			my $qname = B::perlstring( $self->name );
			return eval "sub { for (\@_) { return \@_ if ($inline) }; Type::Tiny::_failed_check(\$type, $qname, \@_ ? \$_[-1] : undef); }";
		}
		elsif ( $func eq 'all' ) {
			return eval "sub { for (\@_) { return !!0 unless ($inline) }; !!1; }";
		}
		elsif ( $func eq 'assert_all' ) {
			my $qname = B::perlstring( $self->name );
			return eval "sub { my \$idx = 0; for (\@_) { Type::Tiny::_failed_check(\$type, $qname, \$_, varname => sprintf('\$_[%d]', \$idx)) unless ($inline); ++\$idx }; \@_; }";
		}
		elsif ( $func eq 'all' ) {
			return eval "sub { for (\@_) { return !!0 unless ($inline) }; !!1; }";
		}
	}

	if ( $func eq 'map' ) {
		my ($inline, $compiled);
		my $c = $self->_assert_coercion;
		
		if ( $c->can_be_inlined ) {
			$inline = $c->inline_coercion('$_');
		}
		else {
			$compiled = $c->compiled_coercion;
			$inline   = '$compiled->($_)';
		}
		
		return eval "sub { map { $inline } \@_ }";
	}

	if ( $func eq 'sort' || $func eq 'rsort' ) {
		my ($inline, $compiled);
		
		my $ptype = $self->find_parent(sub { $_->has_sorter });
		_croak "No sorter for this type constraint" unless $ptype;
		
		my $sorter = $ptype->sorter;
		
		# Schwarzian transformation
		if ( ref($sorter) eq 'ARRAY' ) {
			my $sort_key;
			( $sorter, $sort_key ) = @$sorter;
			
			if ( $func eq 'sort' ) {
				return eval "our (\$a, \$b); sub { map \$_->[0], sort { \$sorter->(\$a->[1],\$b->[1]) } map [\$_,\$sort_key->(\$_)], \@_ }";
			}
			elsif ( $func eq 'rsort' ) {
				return eval "our (\$a, \$b); sub { map \$_->[0], sort { \$sorter->(\$b->[1],\$a->[1]) } map [\$_,\$sort_key->(\$_)], \@_ }";
			}
		}
		
		# Simple sort
		else {
			if ( $func eq 'sort' ) {
				return eval "our (\$a, \$b); sub { sort { \$sorter->(\$a,\$b) } \@_ }";
			}
			elsif ( $func eq 'rsort' ) {
				return eval "our (\$a, \$b); sub { sort { \$sorter->(\$b,\$a) } \@_ }";
			}
		}
	}

	die "Unknown function: $func";
}
1;
