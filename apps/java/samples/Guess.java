public class Guess {
    public static void main(String[] args) throws Exception {
        System.out.println("Guess my digit (0-9), q quits");
        int target = 55;
        while (true) {
            int c = System.in.read();
            if (c == 'q') break;
            if (c < '0' || c > '9') continue;
            if (c == target) { System.out.println(" yes!"); break; }
            if (c < target) System.out.println(" higher");
            else System.out.println(" lower");
        }
        System.out.println("bye");
    }
}
