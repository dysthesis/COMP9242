/*
 * Copyright 2019, Data61
 * Commonwealth Scientific and Industrial Research Organisation (CSIRO)
 * ABN 41 687 119 230.
 *
 * This software may be distributed and modified according to the terms of
 * the GNU General Public License version 2. Note that NO WARRANTY is provided.
 * See "LICENSE_GPLv2.txt" for details.
 *
 * @TAG(DATA61_GPL)
 */
/* Simple shell to run on SOS */

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <syscalls.h>
#include <time.h>
#include <unistd.h>
#include <utils/time.h>
/* Your OS header file */
#include <sos.h>

#include "benchmark.h"

#define BUF_SIZ 6144
#define MAX_ARGS 32
#define THRASH_MAX_PAGES (1u << 20)

static int in;
static sos_stat_t sbuf;

static void prstat(const char *name) {
  /* print out stat buf */
  printf("%c%c%c%c 0x%06x 0x%lx 0x%06lx %s\n",
         sbuf.st_type == ST_SPECIAL ? 's' : '-',
         sbuf.st_fmode & FM_READ ? 'r' : '-',
         sbuf.st_fmode & FM_WRITE ? 'w' : '-',
         sbuf.st_fmode & FM_EXEC ? 'x' : '-', sbuf.st_size, sbuf.st_ctime,
         sbuf.st_atime, name);
}

static int cat(int argc, char **argv) {
  int fd;
  char buf[BUF_SIZ];
  int num_read, stdout_fd, num_written = 0;

  if (argc != 2) {
    printf("Usage: cat filename\n");
    return 1;
  }

  printf("<%s>\n", argv[1]);

  fd = open(argv[1], O_RDONLY);
  stdout_fd = open("console", O_WRONLY);

  assert(fd >= 0);

  while ((num_read = read(fd, buf, BUF_SIZ)) > 0) {
    num_written = write(stdout_fd, buf, num_read);
  }

  close(stdout_fd);
  close(fd);

  if (num_read == -1 || num_written == -1) {
    printf("error on write\n");
    return 1;
  }

  return 0;
}

static int cp(int argc, char **argv) {
  int fd, fd_out;
  char *file1, *file2;
  char buf[BUF_SIZ];
  int num_read, num_written = 0;

  if (argc != 3) {
    printf("Usage: cp from to\n");
    return 1;
  }

  file1 = argv[1];
  file2 = argv[2];

  fd = open(file1, O_RDONLY);
  fd_out = open(file2, O_WRONLY);

  assert(fd >= 0);

  while ((num_read = read(fd, buf, BUF_SIZ)) > 0) {
    num_written = write(fd_out, buf, num_read);
  }

  close(fd_out);
  close(fd);

  if (num_read == -1 || num_written == -1) {
    printf("error on cp\n");
    return 1;
  }

  return 0;
}

#define MAX_PROCESSES 10

static int ps(int argc, char **argv) {
  sos_process_t *process;
  int i, processes;

  process = malloc(MAX_PROCESSES * sizeof(*process));

  if (process == NULL) {
    printf("%s: out of memory\n", argv[0]);
    return 1;
  }

  processes = sos_process_status(process, MAX_PROCESSES);

  printf("TID SIZE   STIME   COMMAND\n");

  for (i = 0; i < processes; i++) {
    printf("%3d %4d %7d %9s\n", process[i].pid, process[i].size,
           process[i].stime, process[i].command);
  }

  free(process);

  return 0;
}

static int exec(int argc, char **argv) {
  pid_t pid;
  int r;
  int bg = 0;

  if (argc < 2 || (argc > 2 && argv[2][0] != '&')) {
    printf("Usage: exec filename [&]\n");
    return 1;
  }

  if ((argc > 2) && (argv[2][0] == '&')) {
    bg = 1;
  }

  if (bg == 0) {
    r = close(in);
    assert(r == 0);
  }

  pid = sos_process_create(argv[1]);
  if (pid >= 0) {
    printf("Child pid=%d\n", pid);
    if (bg == 0) {
      sos_process_wait(pid);
    }
  } else {
    printf("Failed!\n");
  }
  if (bg == 0) {
    in = open("console", O_RDONLY);
    assert(in >= 0);
  }
  return 0;
}

static int dir(int argc, char **argv) {
  int i = 0, r;
  char buf[BUF_SIZ];

  if (argc > 2) {
    printf("Usage: %s [file]\n", argv[0]);
    return 1;
  }

  if (argc == 2) {
    r = sos_stat(argv[1], &sbuf);
    if (r < 0) {
      printf("stat(%s) failed: %d\n", argv[1], r);
      return 0;
    }
    prstat(argv[1]);
    return 0;
  }

  while (1) {
    r = sos_getdirent(i, buf, BUF_SIZ);
    if (r < 0) {
      printf("dirent(%d) failed: %d\n", i, r);
      break;
    } else if (!r) {
      break;
    }
    r = sos_stat(buf, &sbuf);
    if (r < 0) {
      printf("stat(%s) failed: %d\n", buf, r);
      break;
    }
    prstat(buf);
    i++;
  }
  return 0;
}

static int second_sleep(int argc, char *argv[]) {
  if (argc != 2) {
    printf("Usage: %s seconds\n", argv[0]);
    return 1;
  }
  sleep(atoi(argv[1]));
  return 0;
}

static int milli_sleep(int argc, char *argv[]) {
  struct timespec tv;
  uint64_t nanos;
  if (argc != 2) {
    printf("Usage: %s milliseconds\n", argv[0]);
    return 1;
  }
  nanos = (uint64_t)atoi(argv[1]) * NS_IN_MS;
  /* Get whole seconds */
  tv.tv_sec = nanos / NS_IN_S;
  /* Get nanos remaining */
  tv.tv_nsec = nanos % NS_IN_S;
  nanosleep(&tv, NULL);
  return 0;
}

static int second_time(int argc, char *argv[]) {
  printf("%d seconds since boot\n", (int)time(NULL));
  return 0;
}

static int micro_time(int argc, char *argv[]) {
  struct timeval time;
  gettimeofday(&time, NULL);
  uint64_t micros = (uint64_t)time.tv_sec * US_IN_S + (uint64_t)time.tv_usec;
  printf("%lu microseconds since boot\n", micros);
  return 0;
}

static int kill(int argc, char *argv[]) {
  pid_t pid;
  if (argc != 2) {
    printf("Usage: kill pid\n");
    return 1;
  }

  pid = atoi(argv[1]);
  return sos_process_delete(pid);
}

static int benchmark(int argc, char *argv[]) {
  if (argc == 1 || (argc == 2 && strcmp(argv[1], "-d") == 0)) {
    printf("Running benchmark in DEBUG mode. To run in performance mode, use "
           "-p flag\n");
    return sos_benchmark(1);
  } else if (argc == 2 && strcmp(argv[1], "-p") == 0) {
    printf("Running benchmark in PERFORMANCE mode\n");
    return sos_benchmark(0);
  } else {
    printf("Usage: %s [-dp]\n", argv[0]);
    return -1;
  }
}

static int pager_stats_cmd(int argc, char **argv) {
  (void)argc;
  (void)argv;
  sos_pager_stats_t stats = {0};
  if (sos_pager_stats(&stats) < 0) {
    printf("pager_stats failed: errno=%d\n", sos_errno);
    return 1;
  }
  printf("Pager stats: deferred=%" PRIu64 " dedup_hits=%" PRIu64
         " submissions=%" PRIu64 " completions=%" PRIu64 " failures=%" PRIu64
         "\n",
         stats.deferred_faults, stats.dedup_hits, stats.job_submissions,
         stats.job_completions, stats.job_failures);
  return 0;
}

static int thrash_usage(void) {
  printf("Usage: thrash <pages> [--page-size=N] [--pattern=0xNNNNNNNN] "
         "[--passes=N] [--stride=N] [--random] [--noprefault] [--quiet]\n");
  return 1;
}

static void *thrash_aligned_alloc(size_t alignment, size_t bytes) {
  void *ptr = NULL;
  if (posix_memalign(&ptr, alignment, bytes) != 0) {
    return NULL;
  }
  return ptr;
}

static uint32_t thrash_lcg(uint32_t *state) {
  /* 32-bit LCG parameters */
  *state = (*state) * 1664525u + 1013904223u;
  return *state;
}

static void thrash_shuffle(size_t *arr, size_t n, uint32_t seed) {
  uint32_t st = seed;
  for (size_t i = n; i > 1; i--) {
    uint32_t r = thrash_lcg(&st);
    size_t j = r % i;
    size_t tmp = arr[i - 1];
    arr[i - 1] = arr[j];
    arr[j] = tmp;
  }
}

static uint32_t thrash_expected_word(uint32_t base_pattern, size_t page_idx,
                                     size_t word_idx) {
  return base_pattern ^ (uint32_t)(page_idx * 0x9e3779b9u) ^ (uint32_t)word_idx;
}

static int thrash(int argc, char **argv) {
  if (argc < 2) {
    return thrash_usage();
  }

  size_t pages = 0;
  size_t page_size = 4096;
  size_t passes = 1;
  size_t stride = 0;
  uint32_t pattern = 0xfeedfaceu;
  int random = 0;
  int noprefault = 0;
  int quiet = 0;

  pages = strtoul(argv[1], NULL, 0);
  if (pages == 0 || pages > THRASH_MAX_PAGES) {
    printf("thrash: pages must be 1..%u\n", THRASH_MAX_PAGES);
    return 1;
  }

  for (int i = 2; i < argc; i++) {
    if (strncmp(argv[i], "--page-size=", 12) == 0) {
      page_size = strtoul(argv[i] + 12, NULL, 0);
    } else if (strncmp(argv[i], "--pattern=", 10) == 0) {
      pattern = (uint32_t)strtoul(argv[i] + 10, NULL, 0);
    } else if (strncmp(argv[i], "--passes=", 9) == 0) {
      passes = strtoul(argv[i] + 9, NULL, 0);
    } else if (strncmp(argv[i], "--stride=", 9) == 0) {
      stride = strtoul(argv[i] + 9, NULL, 0);
    } else if (strcmp(argv[i], "--random") == 0) {
      random = 1;
    } else if (strcmp(argv[i], "--noprefault") == 0) {
      noprefault = 1;
    } else if (strcmp(argv[i], "--quiet") == 0) {
      quiet = 1;
    } else {
      return thrash_usage();
    }
  }

  if (page_size == 0 || (page_size & (page_size - 1)) != 0) {
    printf("thrash: page-size must be power of two\n");
    return 1;
  }
  if (stride == 0) {
    stride = page_size;
  }
  if (stride < page_size || (stride % page_size) != 0) {
    printf("thrash: stride must be >= page-size and multiple of it\n");
    return 1;
  }
  size_t bytes = (pages - 1) * stride + page_size;

  void *buf = thrash_aligned_alloc(page_size, bytes);
  if (buf == NULL) {
    printf("thrash: allocation failed for %zu bytes\n", bytes);
    return 1;
  }

  size_t *order = malloc(sizeof(size_t) * pages);
  if (order == NULL) {
    printf("thrash: index allocation failed\n");
    free(buf);
    return 1;
  }
  for (size_t i = 0; i < pages; i++) {
    order[i] = i;
  }

  sos_pager_stats_t stats_before = {0}, stats_after = {0};
  (void)stats_before;
  (void)stats_after;
  int have_stats = 0;
  if (sos_pager_stats(&stats_before) == 0) {
    have_stats = 1;
  }

  struct timespec t_start = {0}, t_end = {0};
  clock_gettime(CLOCK_MONOTONIC, &t_start);

  for (size_t pass = 0; pass < passes; pass++) {
    if (random) {
      thrash_shuffle(order, pages, pattern ^ (uint32_t)pass);
    }

    int do_write = !(noprefault && pass == 0);

    if (do_write) {
      for (size_t k = 0; k < pages; k++) {
        size_t idx = order[k];
        uint8_t *page = (uint8_t *)buf + idx * stride;
        uint32_t *words = (uint32_t *)page;
        size_t word_count = page_size / sizeof(uint32_t);
        for (size_t w = 0; w < word_count; w++) {
          words[w] = thrash_expected_word(pattern, idx, w);
        }
      }
    }

    size_t errors = 0;
    for (size_t k = 0; k < pages; k++) {
      size_t idx = order[k];
      uint8_t *page = (uint8_t *)buf + idx * stride;
      uint32_t *words = (uint32_t *)page;
      size_t word_count = page_size / sizeof(uint32_t);
      for (size_t w = 0; w < word_count; w += 1) {
        uint32_t expected = thrash_expected_word(pattern, idx, w);
        if (words[w] != expected) {
          if (!quiet) {
            printf("Mismatch pass %zu page %zu offset %zu got 0x%08x expected "
                   "0x%08x\n",
                   pass, idx, w * 4, words[w], expected);
          }
          errors++;
          break; /* report first error per page to reduce spam */
        }
      }
    }

    if (errors > 0) {
      printf("thrash: FAIL pass %zu errors=%zu\n", pass, errors);
      free(order);
      free(buf);
      return 1;
    } else if (!quiet) {
      printf("thrash: pass %zu OK\n", pass);
    }
  }

  clock_gettime(CLOCK_MONOTONIC, &t_end);
  uint64_t duration_ms = (t_end.tv_sec - t_start.tv_sec) * 1000ull +
                         (t_end.tv_nsec - t_start.tv_nsec) / 1000000ull;

  if (have_stats && sos_pager_stats(&stats_after) == 0) {
    uint64_t sub = stats_after.job_submissions - stats_before.job_submissions;
    uint64_t comp = stats_after.job_completions - stats_before.job_completions;
    uint64_t def = stats_after.deferred_faults - stats_before.deferred_faults;
    uint64_t dedup = stats_after.dedup_hits - stats_before.dedup_hits;
    uint64_t fail = stats_after.job_failures - stats_before.job_failures;
    printf("thrash: pages=%zu passes=%zu time=%" PRIu64
           " ms | pager delta submissions=%" PRIu64 " completions=%" PRIu64
           " deferred=%" PRIu64 " dedup=%" PRIu64 " failures=%" PRIu64 "\n",
           pages, passes, duration_ms, sub, comp, def, dedup, fail);
  } else {
    printf("thrash: pages=%zu passes=%zu time=%" PRIu64 " ms\n", pages, passes,
           duration_ms);
  }

  free(order);
  free(buf);
  return 0;
}

struct command {
  char *name;
  int (*command)(int argc, char **argv);
};

struct command commands[] = {{"dir", dir},
                             {"ls", dir},
                             {"cat", cat},
                             {"cp", cp},
                             {"ps", ps},
                             {"exec", exec},
                             {"sleep", second_sleep},
                             {"msleep", milli_sleep},
                             {"time", second_time},
                             {"mtime", micro_time},
                             {"kill", kill},
                             {"benchmark", benchmark},
                             {"pager_stats", pager_stats_cmd},
                             {"thrash", thrash}};

int main(void) {
  char buf[BUF_SIZ];
  char *argv[MAX_ARGS];
  int i, r, done, found, new, argc;
  char *bp, *p;

  in = open("console", O_RDONLY);
  assert(in >= 0);

  bp = buf;
  done = 0;
  new = 1;

  printf("\n[SOS Starting]\n");

  while (!done) {
    if (new) {
      printf("$ ");
    }
    new = 0;
    found = 0;

    while (!found && !done) {
      /* Make sure to flush so anything is visible while waiting for user input
       */
      fflush(stdout);
      r = read(in, bp, BUF_SIZ - 1 + buf - bp);
      if (r < 0) {
        printf("Console read failed!\n");
        done = 1;
        break;
      }
      bp[r] = 0; /* terminate */
      for (p = bp; p < bp + r; p++) {
        if (*p == '\03') { /* ^C */
          printf("^C\n");
          p = buf;
          new = 1;
          break;
        } else if (*p == '\04') { /* ^D */
          p++;
          found = 1;
        } else if (*p == '\010' || *p == 127) {
          /* ^H and BS and DEL */
          if (p > buf) {
            printf("\010 \010");
            p--;
            r--;
          }
          p--;
          r--;
        } else if (*p == '\n') { /* ^J */
          printf("%c", *p);
          *p = 0;
          found = p > buf;
          p = buf;
          new = 1;
          break;
        } else {
          printf("%c", *p);
        }
      }
      bp = p;
      if (bp == buf) {
        break;
      }
    }

    if (!found) {
      continue;
    }

    argc = 0;
    p = buf;

    while (*p != '\0') {
      /* Remove any leading spaces */
      while (*p == ' ') {
        p++;
      }
      if (*p == '\0') {
        break;
      }
      argv[argc++] = p; /* Start of the arg */
      while (*p != ' ' && *p != '\0') {
        p++;
      }

      if (*p == '\0') {
        break;
      }

      /* Null out first space */
      *p = '\0';
      p++;
    }

    if (argc == 0) {
      continue;
    }

    found = 0;

    for (i = 0; i < sizeof(commands) / sizeof(struct command); i++) {
      if (strcmp(argv[0], commands[i].name) == 0) {
        commands[i].command(argc, argv);
        found = 1;
        break;
      }
    }

    /* Didn't find a command */
    if (found == 0) {
      /* They might try to exec a program */
      if (sos_stat(argv[0], &sbuf) != 0) {
        printf("Command \"%s\" not found\n", argv[0]);
      } else if (!(sbuf.st_fmode & FM_EXEC)) {
        printf("File \"%s\" not executable\n", argv[0]);
      } else {
        /* Execute the program */
        argc = 2;
        argv[1] = argv[0];
        argv[0] = "exec";
        exec(argc, argv);
      }
    }
  }
  printf("[SOS Exiting]\n");
}
