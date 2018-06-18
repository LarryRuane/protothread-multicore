# PROTOTHREAD - multicore library
# See LICENSE (LarryRuane@gmail.com)

# optional
W = \
	-Wstrict-prototypes \
	-W \
	-Wshadow \
	-Wpointer-arith \
	-Wcast-qual \
	-Winline \
	-Wall \

CFLAGS = -O0 -g -m64 -pthread $(W)

all: protothread_test

protothread_test: protothread_test.o protothread.o
	gcc $(CFLAGS) -o protothread_test protothread_test.o protothread.o

protothread_test.o: protothread_test.c
	gcc $(CFLAGS) -c protothread_test.c

protothread.o: protothread.c protothread.h
	gcc $(CFLAGS) -c protothread.c

test: protothread_test
	./protothread_test

clean:
	rm -f *.o protothread_test
