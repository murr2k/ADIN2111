# Makefile for ADIN2111 Unit Tests

CC = gcc
CFLAGS = -Wall -Wextra -g -O0
LDFLAGS = -lcunit

TARGET = test_adin2111
SOURCES = test_adin2111.c
OBJECTS = $(SOURCES:.c=.o)

# XML output for CI/CD
XML_OUTPUT = test-results.xml

.PHONY: all clean test run

all: $(TARGET)

$(TARGET): $(OBJECTS)
	$(CC) $(OBJECTS) -o $(TARGET) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

test: $(TARGET)
	./$(TARGET)

run: test

# Run with XML output (if supported)
test-xml: $(TARGET)
	./$(TARGET) --junit-xml=$(XML_OUTPUT) || true
	@echo "Test results saved to $(XML_OUTPUT)"

# Run with valgrind for memory leak detection
test-valgrind: $(TARGET)
	valgrind --leak-check=full --show-leak-kinds=all ./$(TARGET)

# Coverage analysis (requires gcov)
coverage: CFLAGS += --coverage
coverage: LDFLAGS += --coverage
coverage: clean $(TARGET)
	./$(TARGET)
	gcov $(SOURCES)
	@echo "Coverage report generated"

clean:
	rm -f $(TARGET) $(OBJECTS) *.gcov *.gcda *.gcno $(XML_OUTPUT)

# Install dependencies (Ubuntu/Debian)
install-deps:
	sudo apt-get update
	sudo apt-get install -y libcunit1 libcunit1-dev valgrind

# Help target
help:
	@echo "Available targets:"
	@echo "  make          - Build the test executable"
	@echo "  make test     - Build and run tests"
	@echo "  make test-xml - Run tests with XML output"
	@echo "  make coverage - Run tests with coverage analysis"
	@echo "  make clean    - Remove all build artifacts"
	@echo "  make help     - Show this help message"