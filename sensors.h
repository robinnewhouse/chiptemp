// Reads Apple's built-in temperature sensors (no sudo). Fills `names` (stride bytes each)
// and `vals`; returns how many were read.
int read_sensors(char *names, int stride, double *vals, int max);
