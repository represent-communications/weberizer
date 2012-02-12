Weberizer
=========

Weberizer is a simple templating engine for OCaml.  It compiles the
template to an OCaml module, providing an easy way to set the
variables and render the template.  String values are automatically
escaped according to the context of the template in which they appear.
You can add you own functions to the generated module — for example to
set several related variables at once (you can also hide those
variables from the interface if desired).

This approach will enable to easily add some security features if
desired — like forcing several variables to be set before the template
can be rendered.

Licence
-------

This library is released under the LGPL-3.0 with the OCaml linking
exception.
