function fmap(m, f) { if (typeof m !== 'undefined') { return f(m); } else { return m; } }

var x;
x = 3;

var z = fmap(x, function(y) { return y + 5; });
z = undefined;