CC      = gcc
CFLAGS  = -O2 -Wall -Wextra -g
TARGET  = cat_uring
SRC     = cat.c

.PHONY: all clean run

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $<

run: $(TARGET)
	./$(TARGET) $(FILE)

clean:
	rm -f $(TARGET)
