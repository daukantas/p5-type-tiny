=pod

=encoding utf-8

=head1 PURPOSE

Checks the C<< $type->spec >> method.

=head1 DEPENDENCIES

Test is skipped if Moose is not available.

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

=head1 COPYRIGHT AND LICENCE

This software is copyright (c) 2018 by Toby Inkster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

use Test::More;
use Test::Requires 'Moose';

{
	package Foo;
	use Moose;
	use Types::Standard -types;
	has foo  => HashRef->spec(-default);
	has bar  => ArrayRef->spec(-rw,-default);
	has baz  => Int->spec(-default);
	has quux => Int->spec(-rw);
}

my $obj = Foo->new;

is_deeply(
	$obj,
	bless({ foo => {}, bar => [], baz => 0 }, 'Foo'),
	'defaults work',
);

eval { $obj->foo({xyz => 42}) };
eval { $obj->bar([xyz => 42]) };
eval { $obj->baz(42) };
eval { $obj->quux(99) };

is_deeply(
	$obj,
	bless({ foo => {}, bar => ['xyz',42], baz => 0, quux => 99 }, 'Foo'),
	'spec -rw works',
);

done_testing;
